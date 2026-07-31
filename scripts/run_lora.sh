#!/bin/bash
# LoRaWAN campaigns: LoRaOnly, LoRaOnlyADR and the LoRaWANvsTSCH coexistence scenario.
#
# Usage:  run_lora.sh [options]
#   -c CONFIG   LoRaOnly (default) | LoRaOnlyADR | LoRaWANvsTSCH
#   -n "LIST"   node counts        (default: 20 40 60 80 100 120 140 160 180 200)
#   -r "LIST"   repetitions        (default: 0..7)
#   -p PORT     TCP port           (default: 9800)
#   -o DIR      output directory   (default: <root>/results/<config>)
#   -V          no vector recording -- ~1.8 GB per run saved, .sca unchanged
#   -x "OPT"    extra --key=value passed to the model, repeatable
#   -h          this help
#
# Not parallel, unlike run_tsch.sh, and that is not an oversight. All three configurations
# run on cRealTimeScheduler with realtimescheduler-scaling=1, because the gateways talk to
# a live ChirpStack over MQTT. That pins one simulated second to one wall-clock second:
# 8400 s of simulated time always costs 2 h 20 min, while the model itself uses under 1% of
# a CPU. Throughput is bounded by the clock, not by cores. Running several at once would
# need a port per run, non-colliding shared-memory names and -- the hard part -- separate
# ChirpStack state, since concurrent runs would register the same DevEUIs on one server.
#
# The .ini files carry the firmware paths, so a run launched from the OMNeT++ IDE behaves
# exactly like one launched from here. They were adjusted in one respect: the archived
# files pointed the end-devices at LoRaMac-classA, which no longer builds -- it uses
# NvmCtxMgmt, an API dropped upstream -- so they now name periodic-uplink-lpp, the same
# Class A / AU915 application the project migrated to.
#
# Prerequisites:
#   1. ChirpStack running:  cd <root>/labscim-chirpstack-docker && docker compose up -d
#   2. Devices provisioned for the largest N:
#                           python3 scripts/provision_devices.py --nodes <N>
#   3. Nothing to start by hand for MQTT: the responder is launched below. Delivery is
#      stamped by the gateway path, not by it -- see the comment where it starts.
#   4. For LoRaOnlyADR only: the modified ADR plugin installed server-side (see below).

source "$(dirname "$(readlink -f "$0")")/env.sh"

CONFIG="LoRaOnly"; NS=""; REPS=""; PORT=9800; OUT=""; NOVEC=""; EXTRA=()
while getopts "c:n:r:p:o:x:Vh" opt; do
    case $opt in
        c) CONFIG=$OPTARG ;;
        n) NS=$OPTARG ;;
        r) REPS=$OPTARG ;;
        p) PORT=$OPTARG ;;
        o) OUT=$OPTARG ;;
        V) NOVEC=1 ;;
        x) EXTRA+=("$OPTARG") ;;
        h) sed -n '2,/^[^#]/p' "$0" | sed '$d'; exit 0 ;;
        *) exit 2 ;;
    esac
done

NS=${NS:-"20 40 60 80 100 120 140 160 180 200"}
REPS=${REPS:-"0 1 2 3 4 5 6 7"}
case "$CONFIG" in
    LoRaOnly)      INI_DIR="$ROOT/inis/lora";     INI_PREFIX="labscim-lora" ;;
    LoRaOnlyADR)   INI_DIR="$ROOT/inis/lora-adr"; INI_PREFIX="labscim-lora-adr" ;;
    LoRaWANvsTSCH) INI_DIR="$ROOT/inis/coex";     INI_PREFIX="labscim-lorawanvstsch" ;;
    *) die "unknown config: $CONFIG (LoRaOnly, LoRaOnlyADR or LoRaWANvsTSCH)" ;;
esac
OUT=${OUT:-"$ROOT/results/$CONFIG"}

check_env

FW_LORA="$ROOT/LoRaMac-node/build/src/apps/LoRaMac/LoRaMac-periodic-uplink-lpp"
FW_GW="$ROOT/packet_forwarder/lora_pkt_fwd/lora_pkt_fwd"
[ -x "$FW_LORA" ] || die "LoRa end-device firmware not built: $FW_LORA"
[ -x "$FW_GW" ] || die "packet forwarder not built: $FW_GW"

# packet_forwarder commits its build artifacts, so a fresh clone already contains a
# lora_pkt_fwd binary -- an old one, whose shared-memory handshake no longer matches the
# model. It starts fine and then never completes the rendezvous: the simulation sits at
# "Initializing..." forever with one idle gateway process and no nodes at all. Catch it
# here rather than let it burn an afternoon.
if git -C "$ROOT/packet_forwarder" rev-parse --git-dir >/dev/null 2>&1; then
    if git -C "$ROOT/packet_forwarder" show HEAD:lora_pkt_fwd/lora_pkt_fwd 2>/dev/null \
       | cmp -s - "$FW_GW"; then
        die "the packet forwarder is the prebuilt binary committed in the repository, not a
  local build, and it will hang the simulation at startup. Build it:
      cd $ROOT/lora_gateway && make -j\$(nproc)
      cd $ROOT/packet_forwarder && make -j\$(nproc)
  (lora_gateway first: the packet forwarder links against its libloragw)"
    fi
fi
if [ "$CONFIG" = "LoRaWANvsTSCH" ]; then
    [ -x "$FW_TSCH" ] || die "TSCH firmware not built: $FW_TSCH
  build it with: cd $ROOT/contiki-ng-labscim-tsch/examples/6tisch/simple-node && make -j\$(nproc) TARGET=labscim"
fi

docker ps --format '{{.Names}}' 2>/dev/null | grep -q chirpstack || die \
    "ChirpStack is not running -- cd $ROOT/labscim-chirpstack-docker && docker compose up -d"

# LoRaOnly and LoRaOnlyADR differ by exactly one line: the configuration name. Everything
# that makes the ADR run an ADR run lives on the server -- the adr_labscim.js plugin, the
# adr_plugins entry in chirpstack.toml, and the device profile pointing at it. Without that
# the run completes happily and produces the LoRaOnly curve under an ADR label, which is
# the kind of result nobody notices until it is in a figure.
#
# The mirror mistake is just as damaging and just as quiet: leaving the plugin selected
# while running LoRaOnly labels the modified-ADR curve as the stock one. Both directions
# are checked.
if [ "$CONFIG" = "LoRaOnly" ] || [ "$CONFIG" = "LoRaOnlyADR" ]; then
    alg=$(docker exec -i labscim-chirpstack-docker-postgres-1 psql -U chirpstack \
              -d chirpstack -tAc "select adr_algorithm_id from device_profile limit 1;" \
              2>/dev/null | tr -d '[:space:]')
    [ -n "$alg" ] || die "could not read adr_algorithm_id from the device profile -- is the
  postgres container up?  docker compose ps"
fi
if [ "$CONFIG" = "LoRaOnly" ] && [ "$alg" != "default" ]; then
    die "the device profile uses ADR algorithm '$alg', not the stock 'default', so this run
  would produce the modified-ADR curve under the LoRaOnly label. Switch it back first:
    docker exec -i labscim-chirpstack-docker-postgres-1 psql -U chirpstack -d chirpstack \\
        -c \"update device_profile set adr_algorithm_id = 'default';\"
    cd $ROOT/labscim-chirpstack-docker && docker compose restart chirpstack"
fi
if [ "$CONFIG" = "LoRaOnlyADR" ]; then
    [ "$alg" != "default" ] || die \
"the device profile uses ADR algorithm '${alg:-unknown}', so this would reproduce the
  LoRaOnly curve with an ADR label. Install the modified ADR server-side first:
    1. copy adr_labscim.js into labscim-chirpstack-docker/configuration/chirpstack/
    2. add it to adr_plugins in chirpstack.toml
    3. point the device profile at it (ChirpStack UI, or update device_profile
       set adr_algorithm_id = '<plugin id>')
    4. docker compose restart chirpstack"
fi

mkdir -p "$OUT"
LOG="$OUT/run.log"; STATUS="$OUT/STATUS.txt"

# The MQTT responder subscribes to the uplink events and logs them. It can also echo each
# uplink back to its device, but that is off (SEND_LORA_DOWNSTREAM_REPLY = False) because the
# reference setup has no application downlink at all. It is kept running because its log is
# an uplink count independent of the model's own counters -- useful when a run looks wrong.
#
# Delivery is NOT stamped here. LoRaUpstreamPacketLatency comes from the gateway path:
# lora_pkt_fwd subscribes to the ChirpStack uplink event, computes latency and AoI, and feeds
# LoRaPacketReceived back into the simulator. That subscription is driven by
# MQTTLoggerApplicationTopic in the .ini -- if it stops matching what the server publishes,
# the campaign completes normally, exits 0, and reports PDR = 0 for every point.
REPLY="$MODEL_DIR/PythonScripts/application_reply.py"
[ -f "$REPLY" ] || die "MQTT responder not found: $REPLY"
python3 -c 'import paho.mqtt.client, psycopg2' 2>/dev/null || die \
    "the MQTT responder needs paho-mqtt and psycopg2:
      pip install paho-mqtt psycopg2-binary"

REPLY_PID=""
start_reply() {
    pkill -f 'application_reply\.py' 2>/dev/null
    sleep 1
    python3 -u "$REPLY" > "$OUT/application_reply.log" 2>&1 &
    REPLY_PID=$!
    sleep 3
    kill -0 "$REPLY_PID" 2>/dev/null || die \
        "the MQTT responder died on startup -- see $OUT/application_reply.log"
}
stop_reply() { [ -n "$REPLY_PID" ] && kill "$REPLY_PID" 2>/dev/null; }

echo "$CONFIG campaign"
echo "  model     : $MODEL_BIN"
echo "  end-device: $FW_LORA"
echo "  gateway   : $FW_GW"
[ "$CONFIG" = "LoRaWANvsTSCH" ] && echo "  TSCH      : $FW_TSCH"
echo "  results   : $OUT"
echo "  cost      : ~2h20 per run, serialised by the real-time scheduler"
echo

cleanup() { pkill -9 -f -- "-p$PORT" 2>/dev/null; }

# Clear the OTAA join nonces before every run. ChirpStack records used DevNonces in
# device_keys and rejects repeats, which is correct replay protection -- but the firmware
# restarts from a fresh state each run and reuses them, so from the second run onwards
# every join is refused. The failure is silent from the outside: gateways come online, no
# device ever does. The shipped database also carries nonces from earlier campaigns, so
# even the first run on a fresh clone hits this.
flush_nonces() {
    docker exec -i labscim-chirpstack-docker-postgres-1 psql -U chirpstack -d chirpstack \
        -c "update device_keys set dev_nonces = '{\"0000000000000000\": []}'::jsonb,
                                   join_nonce = 0;" >/dev/null 2>&1 \
        || echo "WARNING: could not flush DevNonces -- joins may be rejected as replays" >&2
}
trap 'cleanup; stop_reply; echo "### INTERRUPTED $(date -Is)" >> "$LOG"; exit 130' INT TERM

start_reply
echo "  MQTT reply: running (pid $REPLY_PID), log in $OUT/application_reply.log"
echo

# Firmware paths deliberately are NOT overridden here: they come from the .ini files, so
# that launching from the OMNeT++ IDE runs exactly what these scripts run. Only settings
# with no sensible fixed value are overridden -- the port, and two INET 4.7 compatibility
# knobs.
OVERRIDES=(
    "--*.contikinghost[*].wlan[*].mac.NodeProcessConnectionPort=$PORT"
    "--*.lorahost[*].wlan[*].mac.NodeProcessConnectionPort=$PORT"
    "--*.radioMedium.sameTransmissionStartTimeCheck=\"ignore\""
    "--*.*.mobility.boundaryPolygonX=[]"
    "--*.*.mobility.boundaryPolygonY=[]"
)

# -V: drop vector recording. Each run writes ~1.8 GB of .vec against ~13 MB of .sca, and the
# curve is built from the .sca alone -- a full campaign is otherwise bounded by disk rather
# than by the clock. Recording is a pure output setting: it consumes no random numbers and
# does not touch the model, so a -V run and a normal run with the same seed produce identical
# scalars. Off by default, because dropping the vectors is irreversible after the fact.
[ -n "$NOVEC" ] && OVERRIDES+=( "--**.vector-recording=false" )

# -x: extra --key=value overrides, repeatable, appended last so they win. For one-off runs
# that are not campaign points -- a short run with the spectrum recorder on, say -- without
# editing the .ini files the campaign is defined by.
[ ${#EXTRA[@]} -gt 0 ] && OVERRIDES+=( "${EXTRA[@]}" )

total=0; done_n=0; failed=0; start=$(date +%s)
for r in $REPS; do for N in $NS; do total=$(( total + 1 )); done; done

# Repetition-major, as in the TSCH runner: an interrupted campaign still leaves a complete
# curve at fewer repetitions rather than a few node counts at full depth.
for r in $REPS; do
    for N in $NS; do
        sca="$OUT/$CONFIG-run-$r-$N.sca"
        # OMNeT++ creates the .sca when the run starts and fills it at the end, so mere
        # existence proves nothing; a complete run is far above 100 kB.
        if [ -f "$sca" ] && [ "$(stat -c%s "$sca")" -gt 100000 ]; then
            done_n=$(( done_n + 1 ))
            echo "### skipping N=$N rep $r (already complete)" >> "$LOG"
            continue
        fi
        echo "=========== N=$N rep $r $(date -Is) ===========" >> "$LOG"
        cleanup; flush_nonces; sleep 2
        t0=$(date +%s)
        ( cd "$NIC_DIR" && "$MODEL_BIN" -r "$r" -m -u Cmdenv -c "$CONFIG" \
            --network="$NETWORK" -n "$NEDPATH" --image-path="$INET_ROOT/images" \
            --result-dir="$OUT" "${OVERRIDES[@]}" \
            "$INI_DIR/$INI_PREFIX-$N.ini" ) >> "$LOG" 2>&1
        rc=$?; t1=$(date +%s)
        done_n=$(( done_n + 1 )); [ $rc -ne 0 ] && failed=$(( failed + 1 ))
        echo "### N=$N rep $r exit=$rc ($(( t1 - t0 ))s) $(date -Is)" >> "$LOG"
        {
            echo "$CONFIG -- updated $(date -Is)"
            echo "done: $done_n / $total  (failed: $failed)"
            echo "last: N=$N rep $r exit=$rc in $(( t1 - t0 ))s"
            echo "elapsed: $(( (t1 - start) / 60 )) min"
        } > "$STATUS"
    done
done

cleanup; stop_reply
echo "### FINISHED $(date -Is) (failed: $failed)" >> "$LOG"
echo
echo "campaign finished. Build the curve with:"
echo "  python3 $ROOT/scripts/analyze_pdr.py $OUT --prefix $CONFIG"
