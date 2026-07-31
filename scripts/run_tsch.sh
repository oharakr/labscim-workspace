#!/bin/bash
# TSCH campaign (Config TSCHOnly) -- reproduces the PDR-vs-N curve of the paper.
#
# Usage:  run_tsch.sh [options]
#   -w N        concurrent runs (default: one per 4 threads, see auto_workers in env.sh)
#   -n "LIST"   node counts        (default: 20 40 60 80 100 120 140 160 180 200)
#   -r "LIST"   repetitions        (default: 0..7 everywhere, 0..20 for N >= 140)
#   -p PORT     base TCP port      (default: 9700; worker k uses PORT + 10*k)
#   -o DIR      output directory   (default: <root>/results/tsch)
#   -V          no vector recording -- saves a lot of disk, .sca unchanged
#   -x "OPT"    extra --key=value passed to the model, repeatable
#   -h          this help
#
# Why more repetitions at high N: the analysis drops runs whose generated-packets-per-node
# falls below 110 (see analyze_pdr.py), and at N >= 160 that filter removes roughly half of
# them. 21 runs there leave about 10 usable, which is the precision the published curve has.
#
# Safe to interrupt and re-run: finished results are skipped.

source "$(dirname "$(readlink -f "$0")")/env.sh"

WORKERS=""; NS=""; REPS_LOW=""; REPS_HIGH=""; BASE_PORT=9700; OUT=""; NOVEC=""; EXTRA=()
while getopts "w:n:r:p:o:x:Vh" opt; do
    case $opt in
        w) WORKERS=$OPTARG ;;
        n) NS=$OPTARG ;;
        r) REPS_LOW=$OPTARG; REPS_HIGH=$OPTARG ;;
        p) BASE_PORT=$OPTARG ;;
        o) OUT=$OPTARG ;;
        V) NOVEC=1 ;;
        x) EXTRA+=("$OPTARG") ;;
        h) sed -n '2,/^[^#]/p' "$0" | sed '$d'; exit 0 ;;
        *) exit 2 ;;
    esac
done

WORKERS=${WORKERS:-$(auto_workers)}
NS=${NS:-"20 40 60 80 100 120 140 160 180 200"}
REPS_LOW=${REPS_LOW:-"0 1 2 3 4 5 6 7"}
REPS_HIGH=${REPS_HIGH:-"0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20"}
OUT=${OUT:-"$ROOT/results/tsch"}
INI_DIR="$ROOT/inis/tsch"

check_env
[ -x "$FW_TSCH" ] || die "TSCH firmware not built: $FW_TSCH
  build it with: cd $ROOT/contiki-ng-labscim-tsch/examples/6tisch/simple-node && make -j\$(nproc) TARGET=labscim"

mkdir -p "$OUT"

# -V drops the vectors, which the curve does not use; -x appends one-off overrides last, so
# they win over the .ini. Same flags as run_lora.sh, and the reason they exist here too is the
# spectrum recorder: a figure needs a short run with it on, which is not a campaign point.
OVERRIDES=()
[ -n "$NOVEC" ] && OVERRIDES+=( "--**.vector-recording=false" )
[ ${#EXTRA[@]} -gt 0 ] && OVERRIDES+=( "${EXTRA[@]}" )

# Job list, repetition-major: an interrupted campaign still leaves a complete curve at
# fewer repetitions rather than a few node counts at full depth.
JOBS=()
for r in $REPS_HIGH; do
    for N in $NS; do
        case " $REPS_LOW " in *" $r "*) hi=0 ;; *) hi=1 ;; esac
        if [ "$hi" -eq 0 ] || [ "$N" -ge 140 ]; then
            JOBS+=("$N:$r")
        fi
    done
done

echo "TSCH campaign"
echo "  workspace : $ROOT"
echo "  model     : $MODEL_BIN"
echo "  firmware  : $FW_TSCH"
echo "  results   : $OUT"
echo "  jobs      : ${#JOBS[@]} on $WORKERS concurrent workers ($(nproc) threads available)"
echo

# One worker: takes every WORKERS-th job, on its own port.
run_worker() {
    local w=$1 port=$(( BASE_PORT + 10 * $1 ))
    local log="$OUT/worker$w.log" status="$OUT/STATUS_worker$w.txt"
    local mine=0 done_n=0 skipped=0 failed=0 start; start=$(date +%s)
    local i N r sca rc t0 t1

    for i in "${!JOBS[@]}"; do [ $(( i % WORKERS )) -eq "$w" ] && mine=$(( mine + 1 )); done
    echo "### worker $w started $(date -Is), port $port, $mine jobs" >> "$log"

    # Only kill what belongs to this worker: the firmware receives "-p<port>" on its
    # command line, so the pattern cannot match another worker's processes.
    kill_mine() { pkill -9 -f -- "-p$port" 2>/dev/null; }
    trap 'kill_mine; exit 130' INT TERM

    for i in "${!JOBS[@]}"; do
        [ $(( i % WORKERS )) -eq "$w" ] || continue
        N=${JOBS[$i]%:*}; r=${JOBS[$i]#*:}
        sca="$OUT/TSCHOnly-run-$r-$N.sca"

        # Resume guard: OMNeT++ creates the .sca when the run starts and only fills it at
        # the end, so mere existence means nothing. A complete run is far above 100 kB;
        # anything smaller is a leftover from an interrupted run and must be redone.
        if [ -f "$sca" ] && [ "$(stat -c%s "$sca")" -gt 100000 ]; then
            skipped=$(( skipped + 1 )); done_n=$(( done_n + 1 ))
            echo "### skipping N=$N rep $r (already complete)" >> "$log"
            continue
        fi

        echo "=========== N=$N rep $r $(date -Is) ===========" >> "$log"
        kill_mine; gc_shm; sleep 2
        t0=$(date +%s)
        ( cd "$NIC_DIR" && "$MODEL_BIN" -r "$r" -m -u Cmdenv -c TSCHOnly \
            --network="$NETWORK" -n "$NEDPATH" --image-path="$INET_ROOT/images" \
            --result-dir="$OUT" \
            "--*.contikinghost[*].wlan[*].mac.NodeProcessConnectionPort=$port" \
            "--*.radioMedium.sameTransmissionStartTimeCheck=\"ignore\"" \
            "--*.*.mobility.boundaryPolygonX=[]" \
            "--*.*.mobility.boundaryPolygonY=[]" \
            "${OVERRIDES[@]}" \
            "$INI_DIR/labscim-tsch-$N.ini" ) >> "$log" 2>&1
        rc=$?; t1=$(date +%s)
        done_n=$(( done_n + 1 )); [ $rc -ne 0 ] && failed=$(( failed + 1 ))
        echo "### N=$N rep $r exit=$rc ($(( t1 - t0 ))s) $(date -Is)" >> "$log"
        {
            echo "worker $w/$WORKERS port $port -- updated $(date -Is)"
            echo "done: $done_n / $mine  (skipped: $skipped, failed: $failed)"
            echo "last: N=$N rep $r exit=$rc in $(( t1 - t0 ))s"
            echo "elapsed: $(( (t1 - start) / 60 )) min"
        } > "$status"
    done

    kill_mine; gc_shm
    echo "### worker $w FINISHED $(date -Is) (failed: $failed)" >> "$log"
    echo "FINISHED $(date -Is) -- $done_n/$mine, failed: $failed" >> "$status"
}

# Shared-memory garbage collector. Segment names do not carry the port, so they cannot be
# scoped per worker; instead drop only segments that no live process references on its
# command line and that are older than 5 minutes -- the window between creating a segment
# and the process showing up in ps is milliseconds, so 5 minutes is a wide margin.
gc_shm() {
    local live
    live=$(ps -eo args | grep -o -- '-nlabscim-[A-Za-z0-9_-]*' | sed 's/^-n//' | sort -u)
    find /dev/shm -maxdepth 1 -name 'labscim-*' -mmin +5 -printf '%f\n' 2>/dev/null | \
    while read -r f; do
        local base=${f%mutex}; base=${base%in}; base=${base%out}
        grep -qx -- "$base" <<< "$live" || rm -f "/dev/shm/$f"
    done
}

pids=()
for (( w = 0; w < WORKERS; w++ )); do
    run_worker "$w" &
    pids+=($!)
    sleep 1
done

echo "workers running. Follow with:"
echo "  tail -f $OUT/worker0.log"
echo "  cat $OUT/STATUS_worker*.txt"
echo
wait "${pids[@]}"

echo
echo "campaign finished $(date -Is)"
grep -h '^FINISHED' "$OUT"/STATUS_worker*.txt 2>/dev/null
echo
echo "now build the curve with:"
echo "  python3 $ROOT/scripts/analyze_pdr.py $OUT"
