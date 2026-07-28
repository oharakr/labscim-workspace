#!/bin/bash
# LoRaWAN campaign (Config LoRaOnly or LoRaOnlyADR).
#
# Usage:  run_lora.sh [options]
#   -c CONFIG   LoRaOnly (default) or LoRaOnlyADR
#   -n "LIST"   node counts        (default: 20 40 60 80 100 120 140 160 180 200)
#   -r "LIST"   repetitions        (default: 0..7)
#   -p PORT     TCP port           (default: 9800)
#   -o DIR      output directory   (default: <root>/results/lora[-adr])
#   -h          this help
#
# NOT parallel, unlike run_tsch.sh, and the difference is not an oversight. The LoRa
# configuration runs on cRealTimeScheduler with realtimescheduler-scaling=1, because the
# gateways talk to a real ChirpStack instance over MQTT. That pins one simulated second to
# one wall-clock second: 8400 s of simulated time always costs 2 h 20 min, while the model
# itself uses under 1% of a CPU. Throughput is bounded by the clock, not by cores.
#
# Running several at once is possible in principle but needs three things this script does
# not do: a port per run, non-colliding shared-memory segment names, and -- the hard one --
# separate ChirpStack state, since every concurrent run would otherwise register the same
# DevEUIs against the same server.
#
# Prerequisites (the co-simulation talks to a live server):
#   1. ChirpStack up:   cd <root>/labscim-chirpstack-docker && docker compose up -d
#   2. Devices provisioned for the largest N you intend to run:
#                       python3 provision_devices.py --nodes <N>
#   3. An MQTT echo responder, so uplinks are answered and end-to-end latency gets stamped.
#
# Status: the TSCH pipeline in run_tsch.sh has been validated end to end against the
# published curve. This one has been validated for a single point (N=20, PDR 0.9835 against
# 0.9847 published); the full sweep has not been run on this layout yet.

source "$(dirname "$(readlink -f "$0")")/env.sh"

CONFIG="LoRaOnly"; NS=""; REPS=""; PORT=9800; OUT=""
while getopts "c:n:r:p:o:h" opt; do
    case $opt in
        c) CONFIG=$OPTARG ;;
        n) NS=$OPTARG ;;
        r) REPS=$OPTARG ;;
        p) PORT=$OPTARG ;;
        o) OUT=$OPTARG ;;
        h) sed -n '2,35p' "$0"; exit 0 ;;
        *) exit 2 ;;
    esac
done

NS=${NS:-"20 40 60 80 100 120 140 160 180 200"}
REPS=${REPS:-"0 1 2 3 4 5 6 7"}
case "$CONFIG" in
    LoRaOnly)    INI_DIR="$ROOT/inis/lora";     OUT=${OUT:-"$ROOT/results/lora"} ;;
    LoRaOnlyADR) INI_DIR="$ROOT/inis/lora-adr"; OUT=${OUT:-"$ROOT/results/lora-adr"} ;;
    *) die "unknown config: $CONFIG (use LoRaOnly or LoRaOnlyADR)" ;;
esac
INI_PREFIX=$([ "$CONFIG" = "LoRaOnlyADR" ] && echo "labscim-lora-adr" || echo "labscim-lora")

check_env
FW_LORA="$ROOT/LoRaMac-node/build/src/apps/LoRaMac/LoRaMac-periodic-uplink-lpp"
[ -x "$FW_LORA" ] || die "LoRa firmware not built: $FW_LORA"
docker ps --format '{{.Names}}' 2>/dev/null | grep -q chirpstack || die \
    "ChirpStack is not running -- cd $ROOT/labscim-chirpstack-docker && docker compose up -d"

mkdir -p "$OUT"
LOG="$OUT/run.log"; STATUS="$OUT/STATUS.txt"

echo "LoRaWAN campaign ($CONFIG)"
echo "  model    : $MODEL_BIN"
echo "  firmware : $FW_LORA"
echo "  results  : $OUT"
echo "  cost     : ~2h20 per run, serialised by the real-time scheduler"
echo

cleanup() { pkill -9 -f -- "-p$PORT" 2>/dev/null; }
trap 'cleanup; echo "### INTERRUPTED $(date -Is)" >> "$LOG"; exit 130' INT TERM

total=0; done_n=0; failed=0; start=$(date +%s)
for r in $REPS; do for N in $NS; do total=$(( total + 1 )); done; done

# Repetition-major, same reasoning as the TSCH runner: an interrupted campaign still
# leaves a complete curve at fewer repetitions.
for r in $REPS; do
    for N in $NS; do
        sca="$OUT/$CONFIG-run-$r-$N.sca"
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
            --result-dir="$OUT" \
            "--*.contikinghost[*].wlan[*].mac.NodeProcessConnectionPort=$PORT" \
            "--*.lorahost[*].wlan[*].mac.NodeProcessConnectionPort=$PORT" \
            "--*.radioMedium.sameTransmissionStartTimeCheck=\"ignore\"" \
            "--*.*.mobility.boundaryPolygonX=[]" \
            "--*.*.mobility.boundaryPolygonY=[]" \
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
