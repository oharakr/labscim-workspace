#!/bin/bash
# LoRaWAN campaigns: LoRaOnly, LoRaOnlyADR and the LoRaWANvsTSCH coexistence scenario.
#
# Usage:  run_lora.sh [options]
#   -c CONFIG   LoRaOnly (default) | LoRaOnlyADR | LoRaWANvsTSCH
#   -n "LIST"   node counts        (default: 20 40 60 80 100 120 140 160 180 200)
#   -r "LIST"   repetitions        (default: 0..7)
#   -p PORT     TCP port           (default: 9800)
#   -o DIR      output directory   (default: <root>/results/<config>)
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
#   3. An MQTT responder echoing uplinks, so end-to-end latency gets stamped.
#   4. For LoRaOnlyADR only: the modified ADR plugin installed server-side (see below).

source "$(dirname "$(readlink -f "$0")")/env.sh"

CONFIG="LoRaOnly"; NS=""; REPS=""; PORT=9800; OUT=""
while getopts "c:n:r:p:o:h" opt; do
    case $opt in
        c) CONFIG=$OPTARG ;;
        n) NS=$OPTARG ;;
        r) REPS=$OPTARG ;;
        p) PORT=$OPTARG ;;
        o) OUT=$OPTARG ;;
        h) sed -n '2,30p' "$0"; exit 0 ;;
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
if [ "$CONFIG" = "LoRaOnlyADR" ]; then
    alg=$(docker exec -i labscim-chirpstack-docker-postgres-1 psql -U chirpstack \
              -d chirpstack -tAc "select adr_algorithm_id from device_profile limit 1;" \
              2>/dev/null | tr -d '[:space:]')
    [ -n "$alg" ] && [ "$alg" != "default" ] || die \
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

echo "$CONFIG campaign"
echo "  model     : $MODEL_BIN"
echo "  end-device: $FW_LORA"
echo "  gateway   : $FW_GW"
[ "$CONFIG" = "LoRaWANvsTSCH" ] && echo "  TSCH      : $FW_TSCH"
echo "  results   : $OUT"
echo "  cost      : ~2h20 per run, serialised by the real-time scheduler"
echo

cleanup() { pkill -9 -f -- "-p$PORT" 2>/dev/null; }
trap 'cleanup; echo "### INTERRUPTED $(date -Is)" >> "$LOG"; exit 130' INT TERM

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
        cleanup; sleep 2
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

cleanup
echo "### FINISHED $(date -Is) (failed: $failed)" >> "$LOG"
echo
echo "campaign finished. Build the curve with:"
echo "  python3 $ROOT/scripts/analyze_pdr.py $OUT --prefix $CONFIG"
