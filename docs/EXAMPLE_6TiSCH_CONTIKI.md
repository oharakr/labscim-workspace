# 6TiSCH Contiki-NG Example

The `TSCHOnly` configuration: a Contiki-NG 6TiSCH network with one coordinator and N−1
nodes, each sending one packet per 60 s, reported as packet delivery ratio against network
size.

It needs no network server and no Docker, and it is the only scenario that runs in
parallel — start here. Requires the [installation guide](INSTALLATION.md).

### 1. Build the firmware
```bash
cd $LABSCIM_WORKSPACE_ROOT/contiki-ng-labscim-tsch/examples/6tisch/simple-node && \
    make -j$(nproc) TARGET=labscim
```

This is `contiki-ng-labscim-tsch`, the pinned checkout — not the `contiki-ng` tree the model
compiles against.

### 2. Configuration files
One `.ini` per node count in `inis/tsch/`, from `labscim-tsch-20.ini` to
`labscim-tsch-200.ini`, each carrying `[Config TSCHOnly]`. They are the archived files
verbatim, except that firmware paths resolve through `$LABSCIM_WORKSPACE_ROOT`.

There is a file per N rather than an iteration variable because the deployment area scales
with the node count: what grows with N is the hop depth of the tree, not the density of the
neighbourhood.

### 3. Run
```bash
cd $LABSCIM_WORKSPACE_ROOT
./scripts/run_tsch.sh -n 20 -r 0 -V        # one point, about a minute
./scripts/run_tsch.sh                      # full campaign
```

| Option | Meaning |
|---|---|
| `-n "LIST"` | node counts (default 20…200 by 20) |
| `-r "LIST"` | repetitions (default 0–7, and 0–20 for N ≥ 140) |
| `-w N` | concurrent runs (default: one per 4 threads) |
| `-V` | no vector recording — saves ~1.8 GB per run, `.sca` unchanged |
| `-o DIR` | output directory (default `results/tsch`) |

Concurrency defaults to `nproc / 4` because each run is one model process plus N firmware
processes. An N=200 run alone takes about 3000 s; four at once, about 5000 s each — denser
buys contention, not throughput.

Safe to interrupt and restart: finished results are skipped, and the job order is
repetition-major, so stopping early leaves a complete curve at fewer repetitions rather than
a few node counts at full depth.

While a run is up, `pgrep -c -f node.labscim` should report N+1. Exactly one firmware
process, idle, means the model never connected — check `LABSCIM_WORKSPACE_ROOT`.

### 4. Analyse
```bash
python3 scripts/analyze_pdr.py results/tsch
```

```
   N |   PDR (filtered)    kept | PDR (all runs) |  hops
------------------------------------------------------------
  20 |  0.9996 +-0.0000   1/1   |         0.9996 |  1.89
```

The metric is `sum(UpstreamPacketLatency.count) / sum(UpstreamPacketGenerated.count)` over
the end devices — latency is only recorded for packets delivered end to end, so its count is
the numerator.

**The published curve is not the plain mean.** Runs generating fewer than 110 packets per
node are discarded, against a nominal 120, which removes runs where the network never
stabilised. At N ≥ 160 that drops roughly half of them, which is why the campaign uses 21
repetitions there. The script prints filtered and unfiltered side by side so the effect of
that choice stays visible.

### 5. Reference values
Filtered, on OMNeT++ 6.4.0 + INET 4.7.0:

| N | published | reproduced | kept |
|---|---|---|---|
| 20 | 0.9992 | 0.9993 | 8/8 |
| 60 | 0.9934 | 0.9955 | 7/8 |
| 100 | 0.9833 | 0.9816 | 8/8 |
| 140 | 0.9453 | 0.9628 | 15/21 |
| 180 | 0.9329 | 0.9173 | 9/21 |
| 200 | 0.8762 | 0.9199 | 6/21 |

Mean absolute deviation 0.0100 over the ten points.

Mean hop count is a useful sanity signal on its own: about 4.8–5.0 at large N. A tree
roughly 1.8 hops shallower means you are running against stock INET, without the
RayleighFading revert.

### 6. Output files
```
results/tsch/TSCHOnly-run-<r>-<N>.sca
results/tsch/worker<k>.log          per-run stdout, exit codes, durations
results/tsch/STATUS_worker<k>.txt
```

`pthread_mutex_destroy: Device or resource busy` on teardown is expected noise; the line
that matters is `### N=<N> rep <r> exit=0`.

To run this from the OMNeT++ IDE instead, see [INSTALLATION_IDE.md](INSTALLATION_IDE.md).
