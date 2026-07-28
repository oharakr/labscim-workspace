#!/usr/bin/env python3
"""Provision the LabSCim ChirpStack instance for a campaign of N nodes: create the missing
devices, write the per-node root key, and repair user password hashes.

Supersedes provision_keys.py, which only UPDATEd device_keys rows that already existed and
therefore could not run with more nodes than the bundled database happened to ship.

  Per-node key: the model computes AppKey = SHA1("node-<mac hex>") and sends it at boot
  (LoRaMacNodeGlueMac.cc:134); the firmware installs the first 16 bytes into the secure
  element as NWK_KEY/APP_KEY. The same key must exist in device_keys or the join fails on
  MIC. With the shared demo key (2B7E...) one device accepts another's JoinAccept -- the
  JoinAccept does not identify its recipient -- which collides DevAddrs and produces mute
  nodes that generate uplinks but deliver none.

  Password hashes: the bundled database carries hashes in an old pbkdf2 format (i=1,l=64)
  that ChirpStack >= 4.19 cannot parse, which makes logging in impossible. The accepted
  format is $pbkdf2-sha512$i=10000$<salt>$<dk>, with a 16-byte salt and a 32-byte derived
  key, in the "adapted" base64 passlib uses (padding stripped, '+' replaced by '.').

Usage:
  provision_devices.py --status
  provision_devices.py --nodes 500                 # create what is missing, write keys
  provision_devices.py --nodes 500 --dry-run
  provision_devices.py --fix-admin                 # make admin/admin work again
  provision_devices.py --fix-user someone --password secret
  provision_devices.py --demo-keys                 # restore the shared key (original behaviour)
"""
import argparse
import base64
import hashlib
import os
import secrets
import subprocess
import sys

DEMO_KEY = "2b7e151628aed2a6abf7158809cf4f3c"
CONTAINER = os.environ.get("CHIRPSTACK_PG", "labscim-chirpstack-docker-postgres-1")
PG = ["docker", "exec", "-i", CONTAINER, "psql", "-U", "chirpstack", "-d", "chirpstack"]

# DevEUI prefix used by the model. The counter is the interface MAC, and an end-device's
# DevEUI is 00000aaa<mac as 8 hex digits>.
#
# MACs 1 and 2 always belong to the two packet forwarders (lorahost[0..1] in the .ini),
# which register as "gateway-node-<mac>" (PacketForwarderNodeGlueMac.cc:116) and never as
# LoRaWAN devices -- so the first end-device is MAC 3.
#
# Hence --nodes N follows the .ini semantics (N = numLoRaHosts, gateways included): the
# end-devices are counters 3..N, that is N-2 devices.
EUI_PREFIX = "00000aaa"
FIRST_COUNTER = 3
GATEWAY_COUNTERS = 2


def psql(sql, tuples_only=True):
    cmd = PG + (["-tAc"] if tuples_only else ["-c"])
    r = subprocess.run(cmd + [sql], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed: {r.stderr.strip()}")
    return r.stdout.strip()


def eui_for(counter):
    return f"{EUI_PREFIX}{counter:08x}"


def node_key(dev_eui_hex):
    """Map a DevEUI to the model's node name (node-aaa000000XX) and its derived key."""
    node_name = "node-" + dev_eui_hex[4:].lstrip("0").rjust(8, "0")
    return hashlib.sha1(node_name.encode()).hexdigest()[:32], node_name


# ---------------------------------------------------------------- devices

def existing_euis():
    out = psql("select encode(dev_eui,'hex') from device order by dev_eui;")
    return [l for l in out.splitlines() if l]


def template_eui(euis):
    """The most recent device serves as a template: we clone its whole row."""
    if not euis:
        sys.exit("no device in the database to use as a template -- restore the "
                 "postgresqldata shipped with labscim-chirpstack-docker first.")
    return euis[-1]


def create_devices(missing, tmpl, dry_run):
    """Clone the template row through jsonb, overriding only what is per-device.

    The to_jsonb/jsonb_populate_record round trip copies every column without naming any
    of them, so this keeps working if a future ChirpStack schema adds columns.
    """
    if not missing:
        return
    values = ",".join(
        f"({c},'\\x{eui_for(c)}','labscim-node-{c}')" for c in missing)
    sql = f"""
    WITH tmpl AS (SELECT * FROM device WHERE dev_eui = '\\x{tmpl}'),
         want(idx, eui, nome) AS (VALUES {values})
    INSERT INTO device
    SELECT (jsonb_populate_record(NULL::device, to_jsonb(t) || jsonb_build_object(
                'dev_eui',             w.eui,
                'name',                w.nome,
                'description',         'LabSCim Simulated Node ' || w.idx,
                'created_at',          to_jsonb(now()),
                'updated_at',          to_jsonb(now()),
                'last_seen_at',        'null'::jsonb,
                'scheduler_run_after', 'null'::jsonb,
                'dev_addr',            'null'::jsonb,
                'secondary_dev_addr',  'null'::jsonb,
                'device_session',      'null'::jsonb,
                'f_cnt_up',            0,
                'battery_level',       'null'::jsonb,
                'margin',              'null'::jsonb,
                'dr',                  'null'::jsonb))).*
    FROM want w, tmpl t
    WHERE NOT EXISTS (SELECT 1 FROM device d WHERE d.dev_eui = w.eui::bytea);
    """
    if dry_run:
        print(f"  (dry-run) would create {len(missing)} devices, "
              f"counters {missing[0]}..{missing[-1]}, template {tmpl}")
        return
    psql(sql)


def write_keys(euis, demo, dry_run):
    rows = []
    for eui in euis:
        key, node_name = (DEMO_KEY, "(demo)") if demo else node_key(eui)
        rows.append((eui, key, node_name))
    if dry_run:
        for eui, key, node_name in rows[:3]:
            print(f"  (dry-run) {eui}  {node_name:<18} -> {key}")
        if len(rows) > 3:
            print(f"  (dry-run) ... and {len(rows)-3} more")
        return
    values = ",".join(f"('\\x{e}'::bytea,'\\x{k}'::bytea)" for e, k, _ in rows)
    psql(f"""
    WITH want(eui, key) AS (VALUES {values})
    INSERT INTO device_keys (dev_eui, created_at, updated_at, nwk_key, app_key,
                             dev_nonces, join_nonce, gen_app_key)
    SELECT eui, now(), now(), key, key, '{{"0000000000000000": []}}'::jsonb, 0,
           '\\x00000000000000000000000000000000'::bytea
    FROM want
    ON CONFLICT (dev_eui) DO UPDATE SET nwk_key = EXCLUDED.nwk_key,
                                        app_key = EXCLUDED.app_key,
                                        updated_at = now();
    """)


# ---------------------------------------------------------------- passwords

def ab64(raw):
    """passlib's adapted base64: padding stripped, '+' becomes '.'."""
    return base64.b64encode(raw).decode().rstrip("=").replace("+", ".")


def password_hash(password, iterations=10000):
    salt = secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha512", password.encode(), salt, iterations, 32)
    return f"$pbkdf2-sha512$i={iterations}${ab64(salt)}${ab64(dk)}"


def fix_user(email, password, dry_run):
    h = password_hash(password)
    print(f"  {email}: password '{password}' -> {h[:32]}...")
    if not dry_run:
        psql(f"update \"user\" set password_hash='{h}', updated_at=now() "
             f"where email='{email}';")


# ---------------------------------------------------------------- status

def status():
    n_dev = psql("select count(*) from device;")
    n_keys = psql("select count(*) from device_keys;")
    n_distinct = psql("select count(distinct nwk_key) from device_keys;")
    demo = psql(f"select count(*) from device_keys where nwk_key='\\x{DEMO_KEY}'::bytea;")
    print(f"devices: {n_dev}   device_keys: {n_keys}   distinct keys: {n_distinct}"
          f"   on the demo key: {demo}")
    print("users (hash format -- i=1 cannot log in on ChirpStack >= 4.19):")
    print(psql("select email, split_part(password_hash,'$',3) from \"user\" order by email;",
               tuples_only=False))
    if n_dev != n_keys:
        print(f"!! {int(n_dev)-int(n_keys)} devices without a key -- run --nodes")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--nodes", type=int, metavar="N",
                    help="ensure N end-devices are provisioned (creates the missing ones)")
    ap.add_argument("--demo-keys", action="store_true",
                    help="write the shared demo key (reproduces the original defect)")
    ap.add_argument("--fix-admin", action="store_true", help="make admin/admin work again")
    ap.add_argument("--fix-user", metavar="EMAIL", help="rewrite another user's hash")
    ap.add_argument("--password", default="admin", help="password for --fix-user")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not any([args.nodes, args.demo_keys, args.fix_admin, args.fix_user, args.status]):
        ap.error("nothing to do -- use --status, --nodes, --fix-admin, ...")

    if args.status:
        status()
        return

    if args.fix_admin:
        fix_user("admin", "admin", args.dry_run)
    if args.fix_user:
        fix_user(args.fix_user, args.password, args.dry_run)

    if args.nodes or args.demo_keys:
        have = existing_euis()
        tmpl = template_eui(have)
        if args.nodes:
            if args.nodes <= GATEWAY_COUNTERS:
                sys.exit(f"--nodes {args.nodes}: the first {GATEWAY_COUNTERS} hosts are the "
                         f"gateways, so N must be greater than {GATEWAY_COUNTERS}")
            want = list(range(FIRST_COUNTER, args.nodes + 1))
            have_set = set(have)
            missing = [c for c in want if eui_for(c) not in have_set]
            print(f"{len(have)} devices in the database; target N={args.nodes} from the .ini "
                  f"= {len(want)} end-devices (counters {want[0]}..{want[-1]}, the first "
                  f"{GATEWAY_COUNTERS} MACs belong to the gateways); missing {len(missing)}")
            create_devices(missing, tmpl, args.dry_run)
            target = [eui_for(c) for c in want]
        else:
            target = have
            print(f"{len(target)} devices in the database")
        write_keys(target, args.demo_keys, args.dry_run)

    # Sessions live in Redis, not in Postgres; since every run joins over OTAA from
    # scratch, there is nothing to clean up here.
    print("\n(dry-run: nothing written)" if args.dry_run else "\nOK.")


if __name__ == "__main__":
    main()
