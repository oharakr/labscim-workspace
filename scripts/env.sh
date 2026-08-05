#!/bin/bash
# Shared environment for the campaign runners. Nothing is executed here -- source it.
#
# Everything is resolved from the workspace root, so the package runs on any machine as
# long as the directory layout is respected:
#
#     <root>/models/labscim/     <- the OMNeT++ model (submodule)
#     <root>/contiki-ng/         <- current Contiki-NG: the model compiles its shared
#                                   sources (labscim_socket, shared_mutex, the setup
#                                   struct) straight out of this tree through symlinks
#     <root>/contiki-ng-labscim-tsch/  <- the TSCH firmware the campaign runs, pinned to
#                                   an older commit. It has to be a second checkout: the
#                                   model needs fields (request_downstream,
#                                   packet_generation_rate_s) that the pinned
#                                   contiki_node_setup struct does not have, so the model
#                                   cannot be built against it. They interoperate because
#                                   the new fields were appended at the end of the struct,
#                                   so the older firmware reads the prefix it knows and
#                                   ignores the tail.
#     <root>/LoRaMac-node/       <- LoRa end-device firmware
#     <root>/lora_gateway/       <- LoRa gateway
#     <root>/packet_forwarder/
#     <root>/inet/               <- INET carrying the RayleighFading revert
#
# The layout is a requirement, not a convention: the headers shared between the model and
# the firmwares are relative symlinks committed in those repositories, and they only
# resolve in this arrangement.
#
# The single external dependency is OMNeT++, which is not a submodule. Point OMNETPP_ROOT
# at it.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The .ini files locate the firmware binaries through $LABSCIM_WORKSPACE_ROOT. The model spawns them
# with popen(), i.e. through /bin/sh, so the shell -- not OMNeT++ -- performs the
# expansion, and any exported variable works. Note the deliberate absence of braces in the
# .ini files: ${...} is OMNeT++'s iteration-variable syntax and would be consumed before
# ever reaching the shell.
#
# Beware the failure mode if this is unset: the path collapses to /contiki-ng/..., popen()
# still succeeds (the shell runs, the command does not), and the model then waits forever
# for a connection that never arrives. It hangs at "Initializing..." instead of failing.
export LABSCIM_WORKSPACE_ROOT="$ROOT"

# OMNeT++ is the one dependency that is not a submodule, so it can be anywhere. It is
# searched for in four stages, stopping at the first hit, cheapest and most authoritative
# first:
#
#   path   opp_run on $PATH. This is what `source omnetpp-6.x/setenv` leaves behind, so it
#          honours the installation the user actually activated -- if two are installed,
#          the activated one wins over anything found by scanning the disk.
#   glob   the conventional locations: next to the workspace, in $HOME, one level below
#          $HOME, and /opt.
#   index  the locate database. Cheap and finds installs in unconventional places, but it
#          cannot be the only mechanism: the index is rebuilt on a daily timer, so an
#          OMNeT++ extracted this morning is invisible to it, and plenty of systems
#          (containers, fresh installs, macOS) have no plocate at all.
#   find   a bounded walk of $HOME. Slow, but it has no prerequisites and sees an install
#          the moment it exists, which is exactly the first-time-reproducer case that the
#          index misses.
#
# Within each stage candidates are sorted by version, descending, so a machine carrying
# both 6.1 and 6.4.0 picks 6.4.0.
# An OMNETPP_ROOT set by the caller is never second-guessed, even when it is wrong: silently
# searching past a typo would run the campaign against a different OMNeT++ than the one that
# was asked for. check_env reports it instead.
OMNETPP_ROOT="${OMNETPP_ROOT:-}"
if [ -z "$OMNETPP_ROOT" ]; then
    for _stage in path glob index find; do
        case $_stage in
            path)  _cands=$(command -v opp_run 2>/dev/null | sed 's|/bin/opp_run$||') ;;
            glob)  _cands=$(ls -d "$ROOT"/../omnetpp-* "$HOME"/omnetpp-* "$HOME"/*/omnetpp-* \
                                  /opt/omnetpp-* 2>/dev/null) ;;
            index) _cands=$( { plocate -r '/bin/opp_run$' 2>/dev/null \
                               || locate -r '/bin/opp_run$' 2>/dev/null; } \
                             | sed 's|/bin/opp_run$||') ;;
            find)  _cands=$(find "$HOME" -maxdepth 4 -type d -name 'omnetpp-*' 2>/dev/null) ;;
        esac
        # read, rather than a for over $_cands, so a path containing spaces survives.
        while IFS= read -r _cand; do
            [ -n "$_cand" ] && [ -x "$_cand/bin/opp_run" ] || continue
            OMNETPP_ROOT="$_cand"
            break
        done <<< "$(printf '%s\n' "$_cands" | sort -Vr)"
        [ -n "$OMNETPP_ROOT" ] && break
    done
    unset _stage _cands _cand
fi
INET_ROOT="${INET_ROOT:-$ROOT/inet}"
MODEL_DIR="$ROOT/models/labscim"
NIC_DIR="$MODEL_DIR/simulations/wireless/nic"
FW_TSCH="$ROOT/contiki-ng-labscim-tsch/examples/6tisch/simple-node/node.labscim"
NETWORK="tsch.simulations.wireless.nic.LabSCimLoRaWANvsTSCH"
NEDPATH="../..:../../../src:$INET_ROOT/src:$INET_ROOT/examples:$INET_ROOT/tutorials:$INET_ROOT/showcases"

# The binary name follows the project directory name, so it cannot be hardcoded.
MODEL_BIN="${MODEL_BIN:-}"
if [ -z "$MODEL_BIN" ] && [ -d "$MODEL_DIR/out" ]; then
    # Prefer a release build. OMNeT++ suffixes the debug binary with _dbg, and with both
    # out/gcc-release/ and out/gcc-debug/ present the plain "find | head -1" below picks
    # between them in directory order -- which silently ran a whole campaign under _dbg.
    MODEL_BIN=$(find "$MODEL_DIR/out" -maxdepth 3 -type f -perm -u+x -name 'labscim*' \
                     ! -name '*.so' ! -name '*_dbg' 2>/dev/null | head -1)
    # Fall back to whatever exists, so a debug-only build still runs.
    [ -n "$MODEL_BIN" ] || MODEL_BIN=$(find "$MODEL_DIR/out" -maxdepth 3 -type f -perm -u+x \
                     -name 'labscim*' ! -name '*.so' 2>/dev/null | head -1)
fi

export LD_LIBRARY_PATH="${OMNETPP_ROOT:-}/lib:$INET_ROOT/src${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

die() { echo "ABORTED: $*" >&2; exit 1; }

check_env() {
    [ -n "$OMNETPP_ROOT" ] && [ -x "$OMNETPP_ROOT/bin/opp_run" ] || die \
        "OMNeT++ not found. Searched \$PATH, $ROOT/.., \$HOME, \$HOME/*, /opt, the locate
  index, and \$HOME to depth 4. Export OMNETPP_ROOT=/path/to/omnetpp-6.x"
    [ -d "$MODEL_DIR" ] || die "model missing at $MODEL_DIR -- run git submodule update --init"
    [ -n "$MODEL_BIN" ] && [ -x "$MODEL_BIN" ] || die \
        "model binary not found under $MODEL_DIR/out -- build the model first"
    [ -d "$INET_ROOT/src" ] || die "INET missing at $INET_ROOT -- run git submodule update --init"

    # Without the RayleighFading revert the curve does NOT reproduce: 4.4.2 applies an
    # amplitude variate to a power ratio, which wipes out deep fades and stretches the
    # range by ~64%. Failing here beats spending days generating garbage.
    local rf="$INET_ROOT/src/inet/physicallayer/wireless/common/pathloss/RayleighFading.cc"
    [ -f "$rf" ] || die "RayleighFading.cc not found under $INET_ROOT"
    grep -q "0.5 \* (x \* x + y \* y)" "$rf" || die \
        "INET without the RayleighFading revert -- check out branch labscim-4.7.0 of the inet submodule"

    local broken
    broken=$(find "$ROOT/models" "$ROOT/LoRaMac-node" "$ROOT/lora_gateway" -xtype l 2>/dev/null | wc -l)
    [ "$broken" -eq 0 ] || die \
        "$broken broken symlinks -- the directory layout is wrong (see the header of this file)"
}

# How many runs to keep in flight. Each run is one model process (~1 full core) plus N
# firmware processes (idle between timeslots, ~20% of a core in total at N=200).
# Measured here: an N=200 run alone takes ~3000s; with 4 concurrent runs, ~5000s. Going
# denser than roughly one run per 4 threads only buys contention, not throughput.
auto_workers() {
    local cores; cores=$(nproc 2>/dev/null || echo 4)
    local w=$(( cores / 4 ))
    [ "$w" -lt 1 ] && w=1
    [ "$w" -gt 8 ] && w=8
    echo "$w"
}
