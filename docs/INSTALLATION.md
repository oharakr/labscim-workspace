# Installation Guide

Verified on **Ubuntu 24.04 LTS**, building every component from a clean clone.

This is the command-line track, which is what the campaign runners use. To work from the
OMNeT++ IDE instead, follow [INSTALLATION_IDE.md](INSTALLATION_IDE.md) — it adds a few
steps to this one rather than replacing it.

The workspace pins the exact commit of every moving part as a git submodule: the model, the
two Contiki-NG checkouts, the LoRa firmware, the gateway, the packet forwarder, and INET.
OMNeT++ is the only component not pinned here.

> **The INET fork is not optional.** Stock INET applies a Rayleigh *amplitude* variate to a
> *power* ratio in `RayleighFading.cc`, which suppresses deep fades and stretches the range
> by about 64%; the published curve does not reproduce against it. The `labscim-4.7.0`
> branch carries the one-line revert, and the runners refuse to start without it.

## Step 1: Install Packages
```bash
sudo apt update
sudo apt install -y build-essential gcc g++ gdb bison flex perl python3 python3-pip \
    pkg-config libxml2-dev zlib1g-dev cmake ninja-build git libssl-dev \
    libcrypto++-dev libboost-all-dev libpaho-mqtt-dev
```

`pkg-config` is easy to miss: without it OMNeT++'s `./configure` stops before writing
`Makefile.inc`.

The Python packages come in two sets. OMNeT++ ships its own pinned list, installed in Step 2
below; these are the ones the campaign scripts need:

```bash
python3 -m pip install --user --upgrade paho-mqtt psycopg2-binary
```

On Ubuntu 24.04 `pip` refuses to write into a system-managed environment: add
`--break-system-packages`, or use a virtualenv, or install the `python3-*` distribution
packages.

## Step 2: Install OMNeT++ 6.4.0
Download the release archive. Keep it **outside** the workspace, so `OMNETPP_ROOT` and
`PATH` cannot drift apart:

```bash
cd $HOME
curl -LO https://github.com/omnetpp/omnetpp/releases/download/omnetpp-6.4.0/omnetpp-6.4.0-linux-x86_64.tgz
tar xvfz omnetpp-6.4.0-linux-x86_64.tgz
```

Take the `linux-x86_64` archive specifically. The `-core` and source distributions are
smaller but ship no IDE, which the [IDE track](INSTALLATION_IDE.md) needs. The same file is
also reachable from <https://omnetpp.org/download/>, which asks for a login; the release
URL above does not.

INET 4.7 requires OMNeT++ 6.4 or later, so this is a coupled upgrade — there is no
"INET 4.7 on OMNeT++ 6.0.3" configuration.

Now **edit `$HOME/omnetpp-6.4.0/configure.user`**. The file comes inside the archive you
just extracted and is what `./configure` reads; all five variables already exist in it, so
change the values in place rather than appending new lines:

```bash
${EDITOR:-nano} $HOME/omnetpp-6.4.0/configure.user
```

```bash
PREFER_CLANG=no
PREFER_LLD=no
WITH_QTENV=no
WITH_OSG=no
WITH_OSGEARTH=no
```

The compiler is chosen here and propagates: `Makefile.inc` sets `CC`/`CXX`, and both INET
and the model inherit them. `WITH_QTENV=no` is a large build-time saving for headless runs;
the IDE track turns it back on.

**Install OMNeT++'s own Python dependencies before configuring** — the build fails without
them:

```bash
cd $HOME/omnetpp-6.4.0
python3 -m pip install --user -r python/requirements.txt
```

That file is the authoritative list (matplotlib, numpy ≥ 2, pandas, scipy, ipython); on
Ubuntu 24.04 it needs the same `--break-system-packages` or virtualenv treatment as Step 1.

Then configure and build:

```bash
source ./setenv && ./configure && make -j$(nproc)
```

Source `setenv` from the OMNeT++ root — it resolves relative paths, and it lasts for the
shell session only.

Plain `make` builds both release and debug. Do not narrow it to `MODE=release`: the OMNeT++
tools link against the debug libraries, and a release-only install later fails with
`opp_msgtool: error while loading shared libraries: liboppnedxml_dbg.so`.

```bash
grep -E '^CC =|^CXX =' Makefile.inc        # expect gcc / g++
ls lib | grep nedxml                       # expect both .so and _dbg.so
```

## Step 3: Clone the Workspace
Clone from `$HOME`, so the workspace lands beside the OMNeT++ tree rather than inside
whatever directory the shell happened to be in:

```bash
cd $HOME
git clone --recurse-submodules https://github.com/oharakr/labscim-workspace.git
cd $HOME/labscim-workspace
export LABSCIM_WORKSPACE_ROOT=$PWD
```

If you cloned without `--recurse-submodules`, use `git submodule update --init` — **without**
`--recursive`, which pulls nested submodules that are not needed.

The `.ini` files locate firmware binaries through `$LABSCIM_WORKSPACE_ROOT`. The runners
export it for you; you need it by hand only for a direct or IDE run. If it is unset the run
hangs at `Initializing...` instead of failing, because `popen()` succeeds while the command
does not.

### The layout is a build requirement

```
labscim-workspace/
├── models/labscim/            the OMNeT++ model
├── contiki-ng/                what the MODEL compiles against
├── contiki-ng-labscim-tsch/   what the CAMPAIGN runs (pinned older)
├── LoRaMac-node/  lora_gateway/  packet_forwarder/
├── inet/                      INET with the RayleighFading revert
├── labscim-chirpstack-docker/ network server for LoRaWAN
├── inis/  scripts/  docs/
```

The headers shared between the model and the firmwares are relative symlinks committed
inside those repositories, and they only resolve in this arrangement. Moving a submodule
breaks the build with a missing-header error that does not name the cause.

Contiki-NG appears twice because the model needs struct fields the pinned firmware does not
have. They interoperate because those fields were appended at the *end* of the struct, so
the firmware reads the prefix it knows and ignores the tail.

## Step 4: Build INET
```bash
cd $LABSCIM_WORKSPACE_ROOT/inet && make makefiles && make -j$(nproc) MODE=release
```

The longest step. Add a debug build too if you intend to debug — see
[INSTALLATION_IDE.md](INSTALLATION_IDE.md).

## Step 5: Build the Model
Do **not** use the repository's own `make makefiles` target: it runs a bare `opp_makemake`
that knows nothing about INET, and the build dies on
`cannot resolve import 'inet.common.INETDefs'`.

```bash
cd $LABSCIM_WORKSPACE_ROOT/models/labscim/src && opp_makemake -f --deep \
  -KINET_PROJ="$LABSCIM_WORKSPACE_ROOT/inet" -DINET_IMPORT \
  -I"$LABSCIM_WORKSPACE_ROOT/inet/src" -L"$LABSCIM_WORKSPACE_ROOT/inet/src" \
  -lcryptopp -lpthread -lrt -lINET
cd .. && make -j$(nproc) MODE=release
```

The binary lands in `models/labscim/out/<toolchain>-release/src/labscim`.

> If you ever build with two compilers, both `out/gcc-release/` and `out/clang-release/`
> exist and `scripts/env.sh` picks between them with `find ... | head -1` — which one is then
> arbitrary. Delete the stale one, or set `MODEL_BIN`, before starting a campaign.

## Step 6: Build the TSCH Firmware
```bash
cd $LABSCIM_WORKSPACE_ROOT/contiki-ng-labscim-tsch/examples/6tisch/simple-node && \
    make -j$(nproc) TARGET=labscim
```

## Step 7: Build the LoRa Components
Only for the LoRaWAN scenarios. None of these binaries ship prebuilt. `lora_gateway` first —
the packet forwarder links against its `libloragw`:

```bash
cd $LABSCIM_WORKSPACE_ROOT/lora_gateway && make -j$(nproc)
cd $LABSCIM_WORKSPACE_ROOT/packet_forwarder && make -j$(nproc)
```

The end-device firmware:

```bash
cd $LABSCIM_WORKSPACE_ROOT/LoRaMac-node && cmake \
  -DCMAKE_BUILD_TYPE:STRING=Release -DAPPLICATION:STRING=LoRaMac \
  -DSUB_PROJECT:STRING=periodic-uplink-lpp -DLORAWAN_DEFAULT_CLASS:STRING=CLASS_A \
  -DCLASSB_ENABLED:STRING=ON -DACTIVE_REGION:STRING=LORAMAC_REGION_AU915 \
  -DMODULATION:STRING=LORA -DBOARD:STRING=labscim \
  -DMBED_RADIO_SHIELD:STRING=LABSCIM_SHIELD -DLORAMAC_LR_FHSS_IS_ON:STRING=ON \
  -DSECURE_ELEMENT:STRING=SOFT_SE -DSECURE_ELEMENT_PRE_PROVISIONED:STRING=OFF \
  -DREGION_EU868:STRING=ON -DREGION_AU915:STRING=ON -DREGION_US915:STRING=OFF \
  -DREGION_CN779:STRING=OFF -DREGION_EU433:STRING=OFF -DREGION_CN470:STRING=OFF \
  -DREGION_AS923:STRING=OFF -DREGION_KR920:STRING=OFF -DREGION_IN865:STRING=OFF \
  -DREGION_RU864:STRING=OFF \
  -DREGION_AS923_DEFAULT_CHANNEL_PLAN:STRING=CHANNEL_PLAN_GROUP_AS923_1 \
  -DREGION_CN470_DEFAULT_CHANNEL_PLAN:STRING=CHANNEL_PLAN_20MHZ_TYPE_A \
  -DUSE_RADIO_DEBUG:STRING=OFF -DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=TRUE \
  -DCMAKE_C_COMPILER:FILEPATH=/usr/bin/gcc -DCMAKE_CXX_COMPILER:FILEPATH=/usr/bin/g++ \
  -S. -B./build -G Ninja
cd build && ninja
```

Produces `build/src/apps/LoRaMac/LoRaMac-periodic-uplink-lpp`, the path the LoRa `.ini`
files name. The application is `periodic-uplink-lpp`, not `LoRaMac-classA`, which no longer
builds — it uses `NvmCtxMgmt`, an API dropped upstream.

If `build/CMakeCache.txt` exists from another path, delete `build/` first: CMake stores
absolute paths and a stale cache configures the wrong source tree.

The LoRaWAN scenarios also need [Docker Engine](https://docs.docker.com/engine/install/ubuntu/),
and your user has to be in the `docker` group. Every `docker compose` call in the example
guides and in `scripts/run_lora.sh` is written without `sudo`, so without the group
membership ChirpStack never comes up and `run_lora.sh` aborts with its "ChirpStack is not
running" check:

```bash
sudo usermod -aG docker $USER
newgrp docker          # this shell only; a new login picks it up everywhere
docker ps              # must succeed without sudo
```

## Step 8: Verify
```bash
cd $LABSCIM_WORKSPACE_ROOT && source scripts/env.sh && check_env && echo OK
```

`check_env` locates OMNeT++, resolves the model binary, greps `RayleighFading.cc` for the
revert, and counts broken symlinks — so a wrong layout surfaces as a message rather than a
missing header.

Then the cheapest end-to-end check, about a minute:

```bash
./scripts/run_tsch.sh -n 20 -r 0 -V -o "$PWD/results/smoke"
python3 scripts/analyze_pdr.py results/smoke
```

Expect a PDR near **0.999** at N=20. While it runs, `pgrep -c -f node.labscim` should report
21. Exactly one firmware process, idle, is the `Initializing...` hang from Step 3.

## Next steps

| Example | Guide |
|---|---|
| 6TiSCH / TSCH-only campaign | [EXAMPLE_6TiSCH_CONTIKI.md](EXAMPLE_6TiSCH_CONTIKI.md) |
| CSMA with RPL and UDP | [EXAMPLE_CSMA_CONTIKI.md](EXAMPLE_CSMA_CONTIKI.md) |
| LoRaWAN, stock ADR | [EXAMPLE_LoRaWAN.md](EXAMPLE_LoRaWAN.md) |
| LoRaWAN, modified ADR | [EXAMPLE_LoRaWAN_ADR.md](EXAMPLE_LoRaWAN_ADR.md) |
| LoRaWAN and TSCH coexisting | [EXAMPLE_COEXISTENCE.md](EXAMPLE_COEXISTENCE.md) |
| Working from the IDE | [INSTALLATION_IDE.md](INSTALLATION_IDE.md) |
