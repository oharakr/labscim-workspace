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
# enabled in every .ini under inis/:
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
# A full campaign point (8400 s, 200 nodes) writes on the order of 150 MB of usage log. To
# turn the recorder off for a run without editing the .ini files:
#
#   scripts/run_lora.sh ... -x "--*.spectrumrecorder.EnableLog=false"
#
# Two versions of spectrum_plotter.py are in the tree, both from github.com/glmoritz/labscim
# at different commits. models/labscim is at the current head, where commit 047ae3b
# ("Updated simulation files and spectrum plotter") dropped the power colour map and left the
# plotter taking a single argument. labscim-chirpstack-docker pins the same repo at an older
# commit that still reads the power log and draws it. This uses the older one, because the
# power map is the point.

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

PLOTTER="$ROOT/labscim-chirpstack-docker/labscim/src/spectrum_plotter/spectrum_plotter.py"
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
