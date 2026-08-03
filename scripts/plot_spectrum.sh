#!/usr/bin/env bash
# Spectrum occupancy figure: what every radio was doing, and where in the band.
#
# Usage:  plot_spectrum.sh [-d DIR] [-f USAGELOG] [-o FILE.png] [-b LO,HI] [-t T0,T1]
#   -d DIR      result directory; picks the newest *-spectrumUsage.txt in it
#               (default: <root>/results)
#   -f FILE     a specific *-spectrumUsage.txt; its *-spectrumPower.txt is inferred
#   -o FILE     write a PNG instead of opening a window -- needed over ssh, or
#               anywhere DISPLAY is unset
#   -b LO,HI    force the frequency axis, in MHz (e.g. 915.1,927.9 for the whole AU915
#               plan). Without it the axis fits the band the run actually occupied, which
#               is what you want per figure but not when comparing figures side by side.
#   -t T0,T1    zoom the time axis, in seconds. A 802.15.4 frame lasts about 2 ms, so on a
#               400 s run it is far thinner than a pixel and the panel reads as empty or,
#               once the run is long enough, as solid black. TSCH needs a window of well
#               under a second to show anything; LoRa frames are ~50-400 ms and survive a
#               wider one. The whole log is still parsed -- this only sets the view.
#
# The plotter does not read the .sca/.vec results. It reads two text logs written by the
# LabscimRadioRecorder module (models/labscim/src/physicallayer/LabscimRadioRecorder.cc),
# configured in every .ini under inis/ but switched off there by default:
#
#   LogName          one line per radio signal -- radio mode, reception state, transmission
#                    state, transmission/reception ended, packetSentToUpper. Drives both
#                    panels: the per-node timeline and the transmission rectangles.
#   SpectrumLogName  the received power function of ONE radio, decomposed into constant /
#                    linear / bilinear pieces. Only written if SpectrumRadioReceiverPath
#                    names a radio, and only at the end of the run, from the destructor --
#                    an interrupted run leaves it empty.
#
# The recorder writes relative to the model's working directory, which is the .ned directory
# and not the result directory, so the .ini paths are built from ${resultdir}.
#
# The .ini files ship with the recorder off, because a full campaign point (8400 s, 200 nodes)
# writes on the order of 150 MB of usage log, and a TSCH point writes far more. Turn it on for
# one short run, without editing the .ini files:
#
#   scripts/run_lora.sh ... -x "--sim-time-limit=300s" \
#                           -x "--*.spectrumrecorder.EnableLog=true"
#
# This runs spectrum_plotter_new.py, not spectrum_plotter.py. The original is upstream's and is
# left exactly as it is, so a figure made before this work can still be reproduced byte for byte;
# everything added here -- the power colour map that commit 047ae3b dropped, the -b and -t
# arguments, and a channel grid chosen from the scenario -- lives in the new file beside it.
#
# A third copy sits at labscim-chirpstack-docker/labscim: the same upstream repo pinned as a
# nested submodule at an older commit. It is not maintained here, and a submodule at a stale pin
# is not somewhere changes can be committed.

set -u
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DIR="$ROOT/results"; USAGE=""; PNG=""; BAND=""; WINDOW=""
while getopts "d:f:o:b:t:h" opt; do
    case $opt in
        d) DIR=$OPTARG ;;
        f) USAGE=$OPTARG ;;
        o) PNG=$OPTARG ;;
        b) BAND=$OPTARG ;;
        t) WINDOW=$OPTARG ;;
        h) sed -n '2,/^[^#]/p' "$0" | sed '$d'; exit 0 ;;
        *) exit 2 ;;
    esac
done

PLOTTER="$ROOT/models/labscim/src/spectrum_plotter/spectrum_plotter_new.py"
[ -s "$PLOTTER" ] || { echo "plotter not found: $PLOTTER" >&2; exit 1; }

if [ -z "$USAGE" ]; then
    USAGE=$(find "$DIR" -name '*-spectrumUsage.txt' -size +1c -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | head -1 | cut -d' ' -f2-)
    [ -n "$USAGE" ] || { echo "no non-empty *-spectrumUsage.txt under $DIR" >&2; exit 1; }
    echo "using $USAGE"
fi
POWER="${USAGE%-spectrumUsage.txt}-spectrumPower.txt"
[ -s "$USAGE" ] || { echo "missing or empty: $USAGE" >&2; exit 1; }
# The power log is written from the destructor. A run killed before the end leaves it empty,
# and the plotter would fail on the first float() of a blank line rather than say why.
[ -s "$POWER" ] || { echo "missing or empty: $POWER
  (written only at the end of a run, and only if SpectrumRadioReceiverPath names a radio)" >&2; exit 1; }

# The usage log is flushed after every signal, so a run killed mid-write leaves a truncated
# last line that the parser chokes on. Trim it from a copy rather than from the log itself.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
sed '$ d' "$USAGE" > "$TMP/usage.txt"

if [ -z "$PNG" ] && [ -z "${DISPLAY:-}" ]; then
    echo "DISPLAY is unset -- pass -o file.png, or the window has nowhere to open" >&2
    exit 1
fi

# Band and window are positional to the plotter, band first, so a window without a band still
# has to pass an empty band to hold the slot.
OPT=()
if [ -n "$WINDOW" ]; then OPT=("$BAND" "$WINDOW")
elif [ -n "$BAND" ]; then OPT=("$BAND")
fi

if [ -n "$PNG" ]; then
    python3 - "$PLOTTER" "$PNG" "$TMP/usage.txt" "$POWER" ${OPT[@]+"${OPT[@]}"} <<'EOF'
import sys, runpy
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

script, out = sys.argv[1], sys.argv[2]
sys.argv = [script] + sys.argv[3:]
plt.show = lambda *a, **k: (plt.gcf().set_size_inches(16, 9),
                            plt.gcf().savefig(out, dpi=120, bbox_inches="tight"))
runpy.run_path(script, run_name="__main__")
EOF
    echo "wrote $PNG"
else
    python3 "$PLOTTER" "$TMP/usage.txt" "$POWER" ${OPT[@]+"${OPT[@]}"}
fi
