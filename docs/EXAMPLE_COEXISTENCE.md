# LoRaWAN / TSCH Coexistence Example

The `LoRaWANvsTSCH` configuration: a LoRaWAN network and a Contiki-NG 6TiSCH network sharing
the same band. It is the only scenario that exercises both stacks at once, so it needs every
component built.

Read [EXAMPLE_6TiSCH_CONTIKI.md](EXAMPLE_6TiSCH_CONTIKI.md) and
[EXAMPLE_LoRaWAN.md](EXAMPLE_LoRaWAN.md) first — this inherits the constraints of both.

### 1. What N means here
Both populations are present at the same count. `labscim-lorawanvstsch-100.ini` sets:

```ini
*.numLoRaHosts       = 100
*.numContikingHosts  = 100
```

against `numContikingHosts = 0` in the LoRa-only files and `numLoRaHosts = 0` in the TSCH
ones. **N = 100 means 200 nodes in the scene**, plus their firmware processes — expect about
`2N` of them. This is the heaviest scenario in both memory and process count.

### 2. Build both firmwares
```bash
cd $LABSCIM_WORKSPACE_ROOT/contiki-ng-labscim-tsch/examples/6tisch/simple-node && \
    make -j$(nproc) TARGET=labscim
```

The LoRa components come from Step 7 of the [installation guide](INSTALLATION.md).
`run_lora.sh` checks for the TSCH firmware explicitly for this configuration.

### 3. Start ChirpStack and provision
```bash
cd $LABSCIM_WORKSPACE_ROOT && ./scripts/chirpstack_up.sh
cd $LABSCIM_WORKSPACE_ROOT
python3 scripts/provision_devices.py --nodes 200
```

Provision for the largest `numLoRaHosts`, not the total node count — only the LoRa side
registers with the server.

### 4. Choose the ADR algorithm deliberately
The device profile's ADR setting applies here too, but unlike `LoRaOnly` and `LoRaOnlyADR`
the runner does **not** guard this configuration. Check it yourself:

```bash
docker exec -i labscim-chirpstack-docker-postgres-1 psql -U chirpstack -d chirpstack \
    -tAc "select adr_algorithm_id from device_profile limit 1;"
```

`default` is stock; `labscimadr` is the modified one from
[EXAMPLE_LoRaWAN_ADR.md](EXAMPLE_LoRaWAN_ADR.md).

### 5. Run
```bash
./scripts/run_lora.sh -c LoRaWANvsTSCH -n 20 -r 0
./scripts/run_lora.sh -c LoRaWANvsTSCH
```

Results in `results/LoRaWANvsTSCH/`, configurations from `inis/coex/`. The 2 h 20 min
real-time cost per run applies: the TSCH side would run far faster alone, but both stacks
share one simulation clock.

### 6. Record the spectrum
This is the scenario where a spectrum figure shows something — both technologies in the same
band. The recorder is off in the campaign files because a TSCH node toggles its radio every
timeslot, costing about 36 kB/s of log against 1.7 kB/s for LoRa.

Turn it on for a short run, without editing the `.ini`:

```bash
./scripts/run_lora.sh -c LoRaWANvsTSCH -n 20 -r 0 \
    -x "--sim-time-limit=300s" -x "--*.spectrumrecorder.EnableLog=true"
```

```bash
./scripts/plot_spectrum.sh -d results/LoRaWANvsTSCH -t 242,242.5 -o coexistence.png
```

`-d` picks the newest log in a directory and `-f` names one explicitly; `-o` writes a PNG
instead of opening a window, needed wherever `DISPLAY` is unset. `-b LO,HI` forces the
frequency axis (e.g. `915.1,927.9` for the whole AU915 plan), which you want when comparing
figures side by side.

Zoom the time axis: a TSCH frame lasts about 2 ms, so a whole run reads as empty or as solid
black. LoRa frames are 50–400 ms and take a wider window.

### 7. Analyse
```bash
python3 scripts/analyze_pdr.py results/LoRaWANvsTSCH --prefix LoRaWANvsTSCH
```

A flat PDR = 0 on the LoRa side points at the `MQTTLoggerApplicationTopic` subscription
rather than at interference — interference degrades a curve, a broken subscription flattens
it while still exiting 0.
