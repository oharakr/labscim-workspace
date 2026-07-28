# LabSCim reproduction workspace

Pinned sources and campaign scripts to regenerate the PDR-vs-N curves of the paper.

The submodules pin the exact commit of every moving part: the model, the two firmwares,
the gateway, and the INET fork carrying the RayleighFading revert. OMNeT++ is the only
component not pinned here; point `OMNETPP_ROOT` at a 6.x installation.

## Layout

```
models/labscim/     OMNeT++ model
contiki-ng/         TSCH firmware      (branch labscim-tsch-sim)
LoRaMac-node/       LoRa end-device firmware
lora_gateway/       LoRa gateway
packet_forwarder/
inet/               INET              (branch labscim-4.7.0)
labscim-chirpstack-docker/            network server for the LoRaWAN scenarios
inis/               the reference .ini files, verbatim
scripts/            campaign runners and analysis
```

**The layout is a build requirement, not a convention.** Headers shared between the model
and the firmwares are relative symlinks committed inside those repositories, and they only
resolve with the model at `models/labscim` and the firmwares as siblings of the root.
Moving a submodule breaks the build with a missing-header error that does not name the
real cause. `find . -xtype l` should report nothing outside `inet/`.

### `LABSCIM_WORKSPACE_ROOT`

The `.ini` files locate the firmware binaries through `$LABSCIM_WORKSPACE_ROOT`. The runners export
it automatically. To launch from the OMNeT++ IDE instead, add it under Run Configuration →
Environment, pointing at the workspace root.

The model spawns firmware with `popen()`, so `/bin/sh` performs the expansion and any
exported variable works. The variable appears without braces on purpose: `${...}` is
OMNeT++'s iteration-variable syntax and would be consumed before reaching the shell.

If the variable is unset the path collapses to `/contiki-ng/...`, `popen()` still succeeds
(the shell runs, the command does not), and the model waits forever for a connection that
never comes — it hangs at `Initializing...` rather than reporting an error. The original
files used `$HOME` for this, which tied the layout to wherever the user happened to keep
their home directory.

## Setup

```bash
git clone --recurse-submodules <this repo> labscim-workspace
cd labscim-workspace
export OMNETPP_ROOT=/path/to/omnetpp-6.4.0

# model
cd models/labscim && make makefiles && make -j$(nproc) && cd ../..

# TSCH firmware
cd contiki-ng/examples/6tisch/simple-node && make -j$(nproc) TARGET=labscim && cd -

# LoRa firmware: the cmake invocation is in models/labscim/documentation/INSTALLATION.md
```

## Running

TSCH, parallel, one run per four hardware threads by default:

```bash
./scripts/run_tsch.sh              # full campaign
./scripts/run_tsch.sh -w 2         # cap concurrency
./scripts/run_tsch.sh -n "20 200" -r "0 1"    # quick check
```

LoRaWAN, necessarily serial (the real-time scheduler pins one simulated second to one
wall-clock second, so each run costs 2 h 20 min regardless of the machine):

```bash
cd labscim-chirpstack-docker && docker compose up -d && cd ..
./scripts/run_lora.sh -c LoRaOnly
./scripts/run_lora.sh -c LoRaOnlyADR
```

Both runners are safe to interrupt and restart: completed results are skipped, and the job
order is repetition-major, so an interrupted campaign leaves a complete curve at fewer
repetitions rather than a few node counts at full depth.

## Reading the results

```bash
python3 scripts/analyze_pdr.py results/tsch
python3 scripts/analyze_pdr.py results/lora --prefix LoRaOnly
```

The published curve is not the plain mean over repetitions: the authors' notebook discards
runs whose generated-packets-per-node falls below 110, which removes the runs where the
network never stabilised. At N >= 160 that is roughly half of them, which is why the
campaign takes 21 repetitions there and 8 elsewhere. `analyze_pdr.py` prints the filtered
and the unfiltered value side by side, so the effect of that choice stays visible.

## Reference values

TSCH Only, filtered, as reproduced on OMNeT++ 6.4.0 + INET 4.7.0:

| N | published | reproduced | kept |
|---|---|---|---|
| 20 | 0.9992 | 0.9993 | 8/8 |
| 60 | 0.9934 | 0.9955 | 7/8 |
| 100 | 0.9833 | 0.9816 | 8/8 |
| 140 | 0.9453 | 0.9628 | 15/21 |
| 180 | 0.9329 | 0.9173 | 9/21 |
| 200 | 0.8762 | 0.9199 | 6/21 |

Mean absolute deviation 0.0100 over the ten points. Only N=200 is individually significant
(t = 2.25, p = 0.025) and it does not survive correction for the four high-N comparisons;
it is also the point with fewest surviving runs.
