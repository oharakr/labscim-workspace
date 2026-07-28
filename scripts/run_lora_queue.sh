#!/bin/bash
# Queue several LoRaWAN campaigns back to back, unattended.
#
# Usage:  run_lora_queue.sh [options]
#   -c "LIST"   configurations, in the order they should run
#               (default: "LoRaOnly LoRaOnlyADR")
#   -n "LIST"   node counts     (default: 20 40 60 80 100 120 140 160 180 200)
#   -r "LIST"   repetitions     (default: 0 1 2)
#   -w          wait for a LoRa simulation already in progress before starting
#   -y          skip the cost estimate confirmation
#   -h          this help
#
# Sequential by construction. The configurations share one ChirpStack instance, one TCP
# port and one set of DevEUIs, so two campaigns at once would corrupt each other's joins
# and sessions. And each run is pinned to the wall clock by cRealTimeScheduler anyway, so
# there is no throughput to gain.
#
# Examples:
#   run_lora_queue.sh -r "0 1 2"                       # curve shape first, 3 repetitions
#   run_lora_queue.sh -n "140 160 180 200" -r "0 1"    # only the high-load points
#   run_lora_queue.sh -c "LoRaWANvsTSCH" -n 200        # a single scenario
#
# Interrupting is cheap: completed results are skipped when the queue is run again, so
# extending 3 repetitions to 8 later only executes what is missing.

source "$(dirname "$(readlink -f "$0")")/env.sh"

HERE="$(dirname "$(readlink -f "$0")")"
CONFIGS="LoRaOnly LoRaOnlyADR"
NS="20 40 60 80 100 120 140 160 180 200"
REPS="0 1 2"
WAIT_RUNNING=0
ASSUME_YES=0

while getopts "c:n:r:wyh" opt; do
    case $opt in
        c) CONFIGS=$OPTARG ;;
        n) NS=$OPTARG ;;
        r) REPS=$OPTARG ;;
        w) WAIT_RUNNING=1 ;;
        y) ASSUME_YES=1 ;;
        h) sed -n '2,28p' "$0"; exit 0 ;;
        *) exit 2 ;;
    esac
done

for c in $CONFIGS; do
    case "$c" in
        LoRaOnly|LoRaOnlyADR|LoRaWANvsTSCH) ;;
        *) die "unknown configuration: $c" ;;
    esac
done

# Cost estimate. Every run costs the same wall-clock time whatever the machine, because
# the real-time scheduler pins one simulated second to one second: sim-time-limit is
# 8400 s, so about 2 h 20 min per run regardless of N or of how many cores are idle.
n_conf=$(wc -w <<< "$CONFIGS"); n_ns=$(wc -w <<< "$NS"); n_reps=$(wc -w <<< "$REPS")
total=$(( n_conf * n_ns * n_reps ))
hours=$(( total * 7 / 3 ))          # 2h20 = 7/3 h

echo "LoRaWAN campaign queue"
echo "  configurations : $CONFIGS"
echo "  node counts    : $NS"
echo "  repetitions    : $REPS"
echo "  runs           : $total  (~$hours h, about $(( hours / 24 )) days if uninterrupted)"
echo "  results        : $ROOT/results/<configuration>"
echo
echo "Already-finished runs are skipped, so the real time will be lower if some exist."
echo

if [ "$ASSUME_YES" -eq 0 ]; then
    read -r -p "start? [y/N] " answer
    case "$answer" in [yY]*) ;; *) echo "aborted."; exit 0 ;; esac
fi

QLOG="$ROOT/results/queue.log"
mkdir -p "$ROOT/results"

# The simulation binary is the reliable thing to wait on: the runner script may already
# have exited while its simulation is still alive, and matching on the script name would
# also match this queue's own command line.
if [ "$WAIT_RUNNING" -eq 1 ]; then
    echo "waiting for a LoRa simulation in progress..." | tee -a "$QLOG"
    while pgrep -f "$(basename "$MODEL_BIN") .*-c LoRa" >/dev/null 2>&1; do sleep 60; done
    echo "none left, starting." | tee -a "$QLOG"
fi

trap 'echo "### QUEUE INTERRUPTED $(date -Is)" | tee -a "$QLOG"; exit 130' INT TERM

echo "### QUEUE STARTED $(date -Is): $total runs" | tee -a "$QLOG"
start_all=$(date +%s)

for c in $CONFIGS; do
    echo "### $c starting $(date -Is)" | tee -a "$QLOG"
    t0=$(date +%s)
    "$HERE/run_lora.sh" -c "$c" -n "$NS" -r "$REPS" >> "$QLOG" 2>&1
    rc=$?
    t1=$(date +%s)
    echo "### $c finished exit=$rc after $(( (t1 - t0) / 60 )) min" | tee -a "$QLOG"
    # Keep going on failure: one broken configuration should not cost the whole queue,
    # and the runner already records per-run exit codes in its own log.
    [ $rc -ne 0 ] && echo "### WARNING: $c exited $rc, continuing" | tee -a "$QLOG"
done

echo "### QUEUE FINISHED $(date -Is), total $(( ( $(date +%s) - start_all ) / 3600 )) h" \
    | tee -a "$QLOG"
echo
echo "curves:"
for c in $CONFIGS; do
    echo "  python3 $HERE/analyze_pdr.py $ROOT/results/$c --prefix $c"
done
