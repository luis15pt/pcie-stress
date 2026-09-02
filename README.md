# C-Payne PCIe Stress Test Tool — extracted contents (rev26)

Extracted from `CPAYNE-TOOL_rev26.img` (FAT16 bootable USB image). The image boots
GRUB with two payloads; the one that matters for testing is **C-Payne-test**, a
busybox initramfs whose contents are reproduced here.

## How the original tool works

Boot flow (`boot-init.sh.txt`, originally `/init` in the initramfs):

1. Interactive menu to pick platform/mainboard (AMD Server ROME/GENOA, WRX80/WRX90,
   Intel, C-Payne PCIe switches, or generic). This only selects which script maps
   PCIe root ports to physical slot names — the tests themselves are identical.
2. Disables PCIe autonomous link speed/width changes and ASPM on all NVIDIA devices:
   `setpci -d 10de: -s '*:*.0' CAP_EXP+30.w=0x0020:0x0020`
   `setpci -d 10de: -s '*:*.0' CAP_EXP+10.w=0x0200:0x0203`
   (keeps the link pinned at max gen/width so errors surface instead of the link
   silently retraining down)
3. Loads the NVIDIA kernel modules, runs `oclBandwidthTest` once as a sanity check.
4. Spawns the test suite across virtual terminals (Alt+F1..F8):

| tty | Script | What it does |
|-----|--------|--------------|
| 1 | `c-payne/page1_aer-stats/launch_page1_aer-stats.sh` | Every 3 s: per-slot link speed/width vs max + AER correctable/nonfatal/fatal counters from `/sys/bus/pci/devices/*/aer_dev_*`. Red = degraded link or nonzero errors. **This is the pass/fail readout.** |
| 2 | `c-payne/page2_margining/` | On demand: `Lane-Margining` (C-Payne's own tool) — PCIe lane margining via the Margining extended capability, per root port. |
| 3 | `c-payne/page3_registers/` | On demand: dumps/decodes PCIe port registers + AER per up/downstream port. |
| 4 | `launch_nvidia_smi.sh` | `nvidia-smi` refresh loop. |
| 5 | `launch_prime.sh` | `mprime -t` (Prime95 torture test) — CPU/memory load. |
| 6 | `launch_oclPCIeStressTest.sh` | **The main PCIe lane exerciser**: 5 threads × up to 32 GPUs of `oclPCIeStressTest 0 <dev>` — C-Payne's own OpenCL tool that loops pinned-host↔device `clEnqueueWriteBuffer`/`clEnqueueReadBuffer` DMA transfers, saturating the PCIe link both directions. |
| 7 | `launch_gpu_burn.sh` | after 60 s: `gpu_burn -tc 10000000` (open-source wili/gpu-burn, tensor-core mode, `compare.ptx` is its result-check kernel) — full GPU compute+VRAM load with error checking. |
| 8 | `launch_nvmePCIeStressTest.sh` | `dd iflag=direct bs=1M` read loop from every `/dev/nvme*n1` — PCIe load on NVMe links. |

Concept: generate maximum simultaneous PCIe traffic (GPU DMA + GPU compute + NVMe
reads + CPU load) and watch the AER error counters and link speed/width. A healthy
system shows 0 AER errors and full speed/width on every slot after hours of load.

## Binaries (`bin/`)

- `oclPCIeStressTest`, `oclBandwidthTest`, `Lane-Margining` — C-Payne's own (closed
  source, but small; dynamically linked against libOpenCL/libpci).
- `gpu_burn` (+ `compare.ptx` in root) — open source, https://github.com/wilicc/gpu-burn
- `mprime` — Prime95. `switchtec` — Microchip switchtec-user CLI.
- Redistributed with permission from C-Payne; see LICENSE for third-party terms.
- `lspci`/`setpci` come from your distro (`apt install pciutils`).

## Running locally (no reboot)

Works on any Linux with the NVIDIA driver loaded. The AER/margining parts read
`/sys/bus/pci` and config space, so they need bare-metal Linux + root
(WSL2 won't expose AER counters or the real PCIe topology; run on the target server).

```bash
# GPU DMA stress on GPU 0 (platform 0, device 0):
./bin/oclPCIeStressTest 0 0

# one-shot host<->device bandwidth:
./bin/oclBandwidthTest

# GPU compute burn, 60 s, tensor cores:
cd cpayne-tests && ./bin/gpu_burn -tc 60    # needs compare.ptx in cwd

# AER / link status for a root port (as root, bare metal):
cd c-payne/page1_aer-stats && ./port.sh 0000:40:01.1
```

Note: the extracted `bin/*` may need the initramfs libs; if your host lacks
libOpenCL/libpci versions they expect, run against `extracted/rootfs-test/lib` via
`LD_LIBRARY_PATH` or use the Docker image (next step).

Boot-image niceties you may want to replicate on a real host before testing:
kernel args `pci=nobar pci=realloc=off pci=norom`, and the two `setpci` commands
above to pin link speed/ASPM.

## Docker

Pull and run **on the GPU server** (needs nvidia-container-toolkit):

```bash
# default = power sweep: 80% -> 90% -> 100% of each GPU's default power limit,
# 1h of gpu_burn+DMA per stage, stop at first dropout, report stable ceiling
docker run --rm -it --privileged --gpus all ghcr.io/luis15pt/pcie-stress:latest
docker run --rm -it --privileged --gpus all ghcr.io/luis15pt/pcie-stress:latest sweep 80,90,100 3600
docker run --rm -it --privileged --gpus all ghcr.io/luis15pt/pcie-stress:latest full 900
```

Stages <=100 are %% of the card's own default limit (works on any GPU model);
values >100 are absolute watts. Cards are always restored to 100%% afterwards.

### Web dashboard (port 8080)

```bash
docker run --rm -it --privileged --gpus all -p 8080:8080 -e WEB_PORT=8080 \
  ghcr.io/luis15pt/pcie-stress:latest            # sweep + live web UI
docker run --rm -d --gpus all -p 8080:8080 \
  ghcr.io/luis15pt/pcie-stress:latest web        # monitoring UI only, no load
```

Set `-e HOST_METRICS_URL=http://<host>:9500/metrics` to add junction and
BAR-level GDDR columns. To be precise about why they are not read in-container:
GDDR and junction temperatures **are** readable, but only from BAR0 MMIO — the
NVIDIA interfaces available to a container report neither
(`temperature.memory` is `N/A` because that field is HBM-only, DCGM field 140
returns a literal `0`, and NVML exposes no junction sensor at all). Reading
BAR0 needs `--privileged` plus the reader binaries in the image, and it would
be a second, ungated source of truth competing with the host's. Pointing at
the host exporter reuses the readings that already passed the validity gate.
Without it those columns read `n/a` — which means "not measured", not "cool".

Dark live dashboard at http://<host>:8080/ — per-GPU cards (util, temp, power,
clocks, VRAM, fan, link, throttle badges, per-run AER delta) with 30-min history
graphs, non-GPU AER table, event feed, and a page-wide red alert the moment any
GPU drops off the bus. Fully self-contained (Chart.js baked into the image).

### Keeping logs when the container dies with the GPU

1. Hosts you own (best): `echo '{"log-driver":"journald"}' | sudo tee /etc/docker/daemon.json && sudo systemctl restart docker` — every container's output survives removal; retrieve with `journalctl CONTAINER_NAME=<name>`.
2. Manual runs: add `-v /var/log/pcie-stress:/log` — output teed to a timestamped file.
3. Managed pods (RunPod etc.): set `-e LOG_URL=https://your-endpoint` — the log is re-POSTed there every 60s.

## Host incident recorder (always-on watchdog)

The container tests on demand; the recorder watches 24/7 and captures the
forensics we kept losing (three dropouts across the fleet left no telemetry:
journals rotated, container logs deleted, nobody noticed for days).

```bash
sudo host/install.sh --journald-cap     # installs systemd service gpu-dropout-recorder
sudo vi /etc/gpu-dropout-recorder.conf  # set WEBHOOK_URL (+ optional IPMI creds)
sudo systemctl restart gpu-dropout-recorder
```

What it does:

- **Telemetry ring**: streams `dcgmi dmon` at 5Hz (power, temps incl. VRAM,
  clocks, util, throttle mask, PCIe replay, XID) to
  `/var/log/gpu-recorder/telemetry.csv` (2 x 100MB generations). DCGM stays
  responsive with a dead GPU (verified on live casualties); nvidia-smi — which
  hangs against dead GPUs — is only a fallback and always timeout-wrapped.
- **Detection** within seconds via DCGM XID field 230 (dead-GPU signature:
  `POWER=N/A SMCLK=N/A XIDER=79`), kernel-log counters (rotation-immune),
  nvidia-smi GPU count, and sampler-stall supervision.
- **Incident bundle** to `/var/log/gpu-recorder/incident-<host>-<ts>/`:
  pre-death telemetry tail, kernel logs, full AER counter dump (they reset on
  reboot!), lspci state (the `7f`), nvidia-smi + GPU serial/UUID map (for
  card-swap tracking), DCGM cached-values snapshot (dead GPUs keep last-known
  temp/power — the value at death), `nvidia-bug-report.log.gz` (--safe-mode),
  meta.json. Oldest bundles pruned beyond 10.
- **Webhook** (Slack-compatible JSON) on every incident; silent if unset.
- Test end-to-end: `sudo kill -USR1 $(systemctl show -p MainPID --value gpu-dropout-recorder)`
  forces a capture with reason `manual-test`.

### Junction (hotspot) temperature — always-on

Vendor guidance: **junction temperature is the best early indicator of a
thermally-failing RTX 5090, and a card sustained above 100 °C junction is due
for service.** No NVIDIA interface reports it — NVML enumerates exactly
one thermal sensor and DCGM has no junction field. (The same applies to VRAM:
GDDR temperatures are perfectly readable, just not through NVIDIA's own
interfaces, where `temperature.memory` is `N/A` because the field is HBM-only
and DCGM field 140 returns a literal `0`.) Both come from BAR0 MMIO instead —
junction via a pinned build of
[ThomasBaruzier/gddr6-core-junction-vram-temps](https://github.com/ThomasBaruzier/gddr6-core-junction-vram-temps).

```bash
sudo host/build-gputemps.sh          # pinned commit, checksum-verified, no CUDA toolkit
sudo host/install.sh                 # readers start in JUNCTION_MODE=observe
sudo gpu-junction-check.sh           # per-GPU table, exit 2 if any card >= 100C
sudo gpu-junction-check.sh --watch
```

Because the number comes from a third-party register offset, **every reading
passes a validity gate before it becomes a metric**: staleness, a cross-check
against NVML core temperature, impossible values, junction-below-core (wrong
profile), and a frozen-register check. Anything rejected is *omitted* rather
than published — a plausible-but-wrong value would defeat the alert this
exists to raise, whereas a gap is alertable with `absent()`. The gate is a pure
function with an offline table test (`host/test_junction_gate.py`, no GPU
needed).

Key metrics on `:9500` — `gpu_junction_temp_celsius` (canonical),
`gpu_junction_core_delta_celsius` (**a rising trend at constant power is
thermal-interface degradation**), `gddr6_vram_temp_max_celsius`,
`gpu_core_temp_celsius{source="nvml"|"gputemps"}` (makes the cross-check
auditable), `gpu_thermal_margin_celsius` (official T.Limit — **lower is
hotter**), plus `gpu_junction_temp_valid`, `gpu_junction_invalid_reason`,
`gpu_junction_map_trusted`, `gpu_junction_reader_up`,
`gpu_junction_parse_errors_total` and `gpu_junction_tool_info`.

`JUNCTION_MODE=observe` (default) publishes the new series and leaves
`DCGM_FI_DEV_HOT_SPOT_TEMP` carrying the GDDR maximum it has always carried.
`authoritative` makes that name mean real junction — **announce it to whoever
owns the central Prometheus before flipping**, since it changes an existing
series' meaning.

The recorder alerts on sustained breaches (95 °C warn / 100 °C service,
per-GPU, escalation-only with an hourly re-notify ceiling) and takes a light
thermal snapshot. It deliberately does **not** capture a full incident bundle
and never disarms dropout detection — a hot card is exactly when you still
want the dropout watchdog live.

Prometheus rules are in `host/prometheus-junction-rules.yml` — deploy on the
Prometheus host. **No `scrape_config` change is needed**: the new series are
already collected by the existing GPU exporter job. Every expression in that
file was evaluated against the live datasource before it was written.

### Screening for a service claim

```bash
sudo gpu-heat-screen.sh --dry-run                    # show the plan, change nothing
sudo gpu-heat-screen.sh --confirm                    # 30 min pytorch soak + verdict
sudo gpu-heat-screen.sh --confirm --method gpuburn --duration 3600
```

**A junction number only supports a service claim if you can state the load it
was measured under.** Junction runs 10–20 °C above core and a 5090 under heavy
load legitimately sits at 100–110 °C, so "over 100 °C" is meaningless without a
defined load and inlet temperature. This script is that definition: it stops
tenant-facing services (and restarts them on every exit path, including Ctrl-C),
suppresses thermal alerting for the run via an **auto-expiring** window,
records per-GPU maxima with throttle reasons, and prints a verdict table
exiting non-zero if any card reached the threshold. Quote the results directory
in the claim — it documents the load, not just the temperature.

Honest limits: power.draw is a ~1s-averaged counter — ms-scale rail transients
are only visible to the BMC/PSU (enable the optional IPMI sampler) or a scope.

Or build locally:

```bash
docker build -t cpayne-test .
docker run --rm -it --privileged --gpus all cpayne-test              # interactive menu
docker run --rm -it --privileged --gpus all cpayne-test full 1800    # 30-min full soak
docker run --rm    --privileged --gpus all cpayne-test preflight     # read-only check
docker run --rm -it --privileged --gpus all cpayne-test margin 0000:00:01.3
```

`--privileged` exposes host sysfs/config space for AER + margining; `--gpus all`
injects the host's driver userspace (nvidia-smi, libcuda, libnvidia-opencl).
The AER monitor and counters reflect the HOST PCIe bus - prerequisite: BIOS must
grant OS-native AER (on ROMED8-2T: "Enable AER Cap" = Enabled and NBIO RAS
"PCIe AER Reporting Mechanism" = OS First), verified via
`dmesg | grep '_OSC'` showing "OS now controls [... AER ...]".
