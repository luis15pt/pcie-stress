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
- `gpu_burn` (+ `compare.ptx` in root) — open source, https://github.com/wili/gpu-burn
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
docker run --rm -it --privileged --gpus all ghcr.io/luis15pt/pcie-stress:latest full 900
```

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
