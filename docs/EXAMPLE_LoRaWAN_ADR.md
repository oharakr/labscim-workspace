# LoRaWAN with Modified ADR

The `LoRaOnlyADR` configuration. Read [EXAMPLE_LoRaWAN.md](EXAMPLE_LoRaWAN.md) first —
this is that scenario plus a server-side algorithm change, and everything about timing,
provisioning and where delivery is measured carries over unchanged.

> **`LoRaOnly` and `LoRaOnlyADR` differ by one line in the simulator: the configuration
> name.** Everything that makes an ADR run an ADR run lives on the ChirpStack server. Run
> `LoRaOnlyADR` without installing the plugin and you get the `LoRaOnly` curve under an ADR
> label — a result nobody notices until it is in a figure. Leaving the plugin selected while
> running `LoRaOnly` is the mirror mistake. `run_lora.sh` checks both directions.

### 1. What it changes
`adr_labscim.js` is ChirpStack's stock default ADR handler with one logic change: the SNR
used for the rate/power margin is the **mean** of per-packet SNR over uplinks at the current
`TxPowerIndex`, instead of the stock **max** over history. The NbTrans table and step logic
are unchanged.

It is a port of the ChirpStack v3 Go plugin `glmoritz/labscimadr`, which the paper's
original `LoRaOnlyADR` data was generated with; the v3 plugin does not load into v4. Plugin
and notes are in `labscim-chirpstack-docker/configuration/chirpstack/`.

### 2. Start ChirpStack
```bash
cd $LABSCIM_WORKSPACE_ROOT/labscim-chirpstack-docker
find postgresqldata -name .gitkeep -delete   # fresh clone only, see EXAMPLE_LoRaWAN.md
docker compose up -d
```

The plugin ships registered — `chirpstack.toml` already has
`adr_plugins = ["/etc/chirpstack/adr_labscim.js"]`, and `configuration/chirpstack` is mounted
at `/etc/chirpstack`. Nothing to copy.

### 3. Select it on the device profile
Registering makes it available, not active. Either set **Device Profile → ADR algorithm →
"LabSCim ADR algorithm"** in the web UI, or:

```bash
docker exec -i labscim-chirpstack-docker-postgres-1 psql -U chirpstack -d chirpstack \
    -c "update device_profile set adr_algorithm_id = 'labscimadr';"
cd $LABSCIM_WORKSPACE_ROOT/labscim-chirpstack-docker && docker compose restart chirpstack
```

Verify before committing hours of run time:

```bash
docker exec -i labscim-chirpstack-docker-postgres-1 psql -U chirpstack -d chirpstack \
    -tAc "select adr_algorithm_id from device_profile limit 1;"     # expect labscimadr
```

### 4. Provision and run
Provisioning is identical to `LoRaOnly` — the keys belong to the devices, not the algorithm:

```bash
cd $LABSCIM_WORKSPACE_ROOT
python3 scripts/provision_devices.py --nodes 200
./scripts/run_lora.sh -c LoRaOnlyADR -n 20 -r 0
```

Results go to `results/LoRaOnlyADR/`. Same 2 h 20 min per run, serial.

### 5. Switching back
```bash
docker exec -i labscim-chirpstack-docker-postgres-1 psql -U chirpstack -d chirpstack \
    -c "update device_profile set adr_algorithm_id = 'default';"
cd $LABSCIM_WORKSPACE_ROOT/labscim-chirpstack-docker && docker compose restart chirpstack
```

`default` is ChirpStack's built-in max-SNR algorithm, the non-modified comparison.

### 6. Analyse
```bash
python3 scripts/analyze_pdr.py results/LoRaOnlyADR --prefix LoRaOnlyADR
```

Keep the two campaigns in separate output directories and label them from the directory. The
simulator configurations are identical, so the `.sca` files are indistinguishable after the
fact.
