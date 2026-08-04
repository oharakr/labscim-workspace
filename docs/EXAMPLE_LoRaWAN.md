# LoRaWAN Example

The `LoRaOnly` configuration: N LoRa hosts — `lorahost[0]` and `lorahost[1]` are gateways,
the rest end devices — uplink only, with the stock ChirpStack ADR algorithm.

Unlike the TSCH scenario this one talks to a **real network server**: joins and uplinks are
carried by a real packet forwarder to a real ChirpStack over MQTT. Requires the
[installation guide](INSTALLATION.md) and
[Docker Engine](https://docs.docker.com/engine/install/ubuntu/).

> **Budget the wall clock first.** All LoRaWAN configurations use `cRealTimeScheduler` with
> `realtimescheduler-scaling = 1`, so one simulated second costs one wall-clock second:
> 8400 s of simulated time is always **2 h 20 min**, however fast the machine. The model
> itself uses under 1% of a CPU. Ten points at eight repetitions is about eleven days, so
> choose `-n` and `-r` deliberately.
>
> This is also why the runner is serial. Parallel runs would need separate ChirpStack state,
> since they would register the same DevEUIs on one server.

### 1. Start ChirpStack
```bash
cd $LABSCIM_WORKSPACE_ROOT
./scripts/chirpstack_up.sh        # seven containers; -d stops them again
```

Use the script rather than `docker compose up -d` directly. On a fresh clone the bare
command leaves `postgres-1` exiting at startup with

```
FATAL: could not open directory "pg_tblspc/.gitkeep/PG_14_202107181": Not a directory
```

The submodule ships an already-provisioned PostgreSQL data directory, so the scenarios start
with the devices registered instead of needing an `initdb`. Git cannot store an empty
directory, so ten `.gitkeep` placeholders hold the ones PostgreSQL wants empty — and
PostgreSQL treats *every* entry under `pg_tblspc/` as a tablespace link and opens it as a
directory. The script creates those ten directories and clears the placeholders before
starting the stack. It is idempotent, so running it again costs nothing.

### 2. Provision the devices
```bash
cd $LABSCIM_WORKSPACE_ROOT
python3 scripts/provision_devices.py --nodes 200
python3 scripts/provision_devices.py --status
```

Do this for the largest N you intend to run. The model derives a per-node root key
(`AppKey = SHA1("node-<mac hex>")`) and hands it to the firmware at boot; the same key must
exist in `device_keys` or the join fails.

If instead every device shares one demo key, the failure is not a clean rejection: a
JoinAccept does not identify its recipient, so devices accept each other's, DevAddrs
collide, and you get **mute nodes that generate uplinks but deliver none**.

### 3. Check the web UI
[http://localhost:8080/](http://localhost:8080/), user and password `admin`. If the login is
refused with correct credentials, the bundled database has password hashes in a format
ChirpStack ≥ 4.19 cannot parse:

```bash
python3 scripts/provision_devices.py --fix-admin
```

### 4. Run
```bash
./scripts/run_lora.sh -c LoRaOnly -n 20 -r 0     # one point
./scripts/run_lora.sh -c LoRaOnly                # full campaign
```

Options match `run_tsch.sh` (`-n`, `-r`, `-V`, `-o`), plus `-p` for the TCP port (default
9800). Results go to `results/LoRaOnly/`.

The runner handles three things that fail silently when forgotten:

- **DevNonce flushing.** ChirpStack rejects repeated DevNonces, and the firmware restarts
  its sequence each run, so from the second run on every join is refused — gateways come
  online and no device ever does. Flushed before each run.
- **The MQTT responder.** `application_reply.py` is started automatically. Its echo-back is
  off, matching the reference setup, which has no application downlink; it is kept running
  because its log is an uplink count independent of the model's counters.
- **The ADR guard.** `LoRaOnly` and `LoRaOnlyADR` differ only by configuration name —
  everything else lives on the server. The runner reads `adr_algorithm_id` from the device
  profile and refuses to start unless it is `default`.

### 5. Where delivery is measured
Not by the MQTT responder. `LoRaUpstreamPacketLatency` comes from the gateway path:
`lora_pkt_fwd` subscribes to the ChirpStack uplink event and feeds `LoRaPacketReceived` back
into the simulator, driven by `MQTTLoggerApplicationTopic` in the `.ini`.

If that topic stops matching what the server publishes, **the campaign completes normally,
exits 0, and reports PDR = 0 at every point.** A flat zero is a broken subscription, not a
broken network.

### 6. Analyse
```bash
python3 scripts/analyze_pdr.py results/LoRaOnly --prefix LoRaOnly
```

Same metric and same ≥ 110 filter as the TSCH scenario — see
[EXAMPLE_6TiSCH_CONTIKI.md](EXAMPLE_6TiSCH_CONTIKI.md).

### 7. Output files
```
results/LoRaOnly/LoRaOnly-run-<r>-<N>.sca
results/LoRaOnly/run.log
results/LoRaOnly/STATUS.txt                 written when the first run completes
results/LoRaOnly/application_reply.log      independent uplink count
```

### 8. Configuration notes
The files in `inis/lora/` are the archived ones with two changes: paths resolve through
`$LABSCIM_WORKSPACE_ROOT`, and the end devices name `periodic-uplink-lpp` instead of
`LoRaMac-classA`, which no longer builds. The real-time lines must stay as they are:

```ini
scheduler-class = "omnetpp::cRealTimeScheduler"
realtimescheduler-scaling = 1
```

From the IDE, the same `.ini` runs unchanged, but the preflight steps above are yours to do
— see [INSTALLATION_IDE.md](INSTALLATION_IDE.md).
