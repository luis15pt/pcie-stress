#!/bin/bash
# Containerized C-Payne PCIe/GPU stress suite.
# Modes: menu (default) | preflight | watch | bandwidth | burn [s] | dma [s] |
#        nvme [s] | full [s] | margin <port-bdf> | shell
cd /opt/cpayne

ngpus() { ls -d /proc/driver/nvidia/gpus/* 2>/dev/null | wc -l; }

monitor() { # monitor [interval] — Rich dashboard, shell fallback
  if [ -f ./docker/aer_watch.py ] && python3 -c 'import rich' 2>/dev/null; then
    python3 ./docker/aer_watch.py "${1:-3}"
  else
    ./docker/aer-watch.sh "${1:-3}"
  fi
}

cleanup() {
  pkill -f oclPCIeStressTest 2>/dev/null
  pkill -f gpu_burn 2>/dev/null
  pkill -f 'dd if=/dev/nvme' 2>/dev/null
}
trap cleanup EXIT INT TERM

dma_stress() { # dma_stress <seconds>
  local secs=$1 n; n=$(ngpus)
  [ "$n" -eq 0 ] && { echo 'No NVIDIA GPUs visible (need --gpus all).'; return 1; }
  echo "PCIe DMA stress: 5 threads x $n GPUs for ${secs}s"
  local dev i
  for dev in $(seq 0 $((n - 1))); do
    for i in 1 2 3 4 5; do
      timeout "$secs" bin/oclPCIeStressTest 0 "$dev" >/dev/null 2>&1 &
    done
  done
}

nvme_stress() { # nvme_stress <seconds>
  local secs=$1 found=0 d
  for d in /dev/nvme*n1; do
    [ -e "$d" ] || continue
    found=1
    echo "NVMe direct-read loop on $d for ${secs}s"
    timeout "$secs" bash -c "while true; do dd if=$d of=/dev/null bs=1M iflag=direct 2>/dev/null; done" &
  done
  [ $found -eq 0 ] && echo 'No NVMe devices visible (mount /dev or use --privileged).'
}

burn() { # burn <seconds> [extra gpu_burn flags...] — flags default to -tc
  local secs=$1; shift
  local flags=("$@"); [ ${#flags[@]} -eq 0 ] && flags=(-tc)
  echo "gpu_burn ${flags[*]} for ${secs}s ..."
  bin/gpu_burn "${flags[@]}" "$secs"
}

full() { # full <seconds>
  local secs=${1:-1800}
  echo "FULL STRESS for ${secs}s: gpu_burn + PCIe DMA + NVMe reads, AER monitor in foreground."
  echo 'Logs: /tmp/gpu_burn.log  -  Ctrl+C stops everything.'
  sleep 2
  bin/gpu_burn -tc "$secs" >/tmp/gpu_burn.log 2>&1 &
  dma_stress "$secs"
  nvme_stress "$secs"
  if [ -f ./docker/aer_watch.py ] && python3 -c 'import rich' 2>/dev/null; then
    timeout --foreground "$secs" python3 ./docker/aer_watch.py 2
  else
    timeout --foreground "$secs" ./docker/aer-watch.sh 3
  fi
  cleanup
  echo ''
  echo '=== gpu_burn result ==='
  tail -12 /tmp/gpu_burn.log
  echo ''
  echo '=== final AER state (nonzero correctable counters) ==='
  grep -H . /sys/bus/pci/devices/*/aer_dev_correctable 2>/dev/null | grep TOTAL_ERR_COR | grep -v ':TOTAL_ERR_COR 0$' || echo 'all zero - clean run'
}

menu() {
  while true; do
    echo ''
    echo 'C-Payne PCIe Stress Test (containerized) - c-payne.com tool, repacked'
    echo ''
    echo '1) preflight   - link/register/AER state, saves restore file'
    echo '2) watch       - live AER/link monitor'
    echo '3) bandwidth   - one-shot host<->GPU bandwidth (oclBandwidthTest)'
    echo '4) burn        - gpu_burn tensor-core load, 300s'
    echo '5) dma         - PCIe DMA stress all GPUs, 1800s'
    echo '6) nvme        - NVMe direct-read stress, 1800s'
    echo '7) full        - everything + monitor, 1800s'
    echo '8) margin      - PCIe lane margining (asks for root port BDF)'
    echo '9) shell'
    echo 'q) quit'
    read -r -p '> ' n
    case $n in
      1) ./preflight.sh ;;
      2) monitor 3 ;;
      3) bin/oclBandwidthTest ;;
      4) burn 300 ;;
      5) dma_stress 1800; wait ;;
      6) nvme_stress 1800; wait ;;
      7) full 1800 ;;
      8) read -r -p 'root port BDF (e.g. 0000:00:01.3): ' p
         bin/Lane-Margining -s "$p" -t "containerized" ;;
      9) bash ;;
      q) exit 0 ;;
    esac
  done
}

case "${1:-menu}" in
  menu)      menu ;;
  preflight) ./preflight.sh ;;
  watch)     monitor "${2:-3}" ;;
  bandwidth) bin/oclBandwidthTest ;;
  burn)      shift; burn "${1:-300}" "${@:2}" ;;
  dma)       dma_stress "${2:-1800}"; wait ;;
  nvme)      nvme_stress "${2:-1800}"; wait ;;
  full)      full "${2:-1800}" ;;
  margin)    bin/Lane-Margining -s "$2" -t "containerized" ;;
  shell)     exec bash ;;
  *)         echo "unknown mode: $1"; exit 1 ;;
esac
