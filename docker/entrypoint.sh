#!/bin/bash
# Containerized C-Payne PCIe/GPU stress suite.
# Modes: sweep [stages] [dwell] (default: 80,90,100 x 3600s) | menu | preflight | watch |
#        bandwidth | burn [s] [flags] | dma [s] | nvme [s] | full [s] | margin <port> | shell
cd /opt/cpayne

# Log persistence — a GPU drop usually ends with the container removed and
# docker logs gone (RunPod, --rm). Three options, in order of preference:
#   1. host journald:  {"log-driver":"journald"} in /etc/docker/daemon.json (no
#      container config needed; recommended on hosts you own)
#   2. -v host:/log    (manual runs): output teed to a timestamped file
#   3. LOG_URL=http(s)://... : log file re-POSTed there every 60s (works on
#      RunPod-style pods where you control neither docker run nor the host)
LOGFILE=""
if [ -d /log ]; then
  LOGFILE="/log/pcie-stress-$(date +%Y%m%d-%H%M%S).log"
elif [ -n "${LOG_URL:-}" ]; then
  LOGFILE="/tmp/pcie-stress-run.log"
fi
if [ -n "$LOGFILE" ]; then
  exec > >(tee -a "$LOGFILE") 2>&1
fi
if [ -n "${LOG_URL:-}" ] && [ -n "$LOGFILE" ]; then
  ( off=0
    while sleep 15; do
      sz=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
      if [ "$sz" -gt "$off" ]; then
        if tail -c +$((off + 1)) "$LOGFILE" | curl -fsS -X POST \
             -H 'Content-Type: text/plain' -H "X-Log-Offset: $off" \
             --data-binary @- "$LOG_URL" >/dev/null 2>&1; then
          off=$sz
        fi
      fi
    done ) &
fi

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

new_dropouts() { # count of 'fallen off the bus' kernel lines
  dmesg 2>/dev/null | grep -c 'fallen off the bus'
}

set_limits() { # set_limits <stage>  — stage <=100 means % of each GPU's default limit, >100 means watts
  local stage=$1 line idx dflt min tgt
  while IFS=, read -r idx dflt min; do
    idx=$(echo "$idx" | tr -d ' '); dflt=${dflt%%.*}; min=${min%%.*}
    if [ "$stage" -le 100 ]; then tgt=$((dflt * stage / 100)); else tgt=$stage; fi
    [ "$tgt" -lt "$min" ] && tgt=$min
    [ "$tgt" -gt "$dflt" ] && tgt=$dflt
    nvidia-smi -i "$idx" -pl "$tgt" >/dev/null || return 1
    echo "  GPU $idx: limit ${tgt}W (default ${dflt}W)"
  done < <(nvidia-smi --query-gpu=index,power.default_limit,power.min_limit --format=csv,noheader,nounits)
}

sweep() { # sweep <stages: % of default limit (or watts if >100)> <dwell seconds per stage>
  local stages=${1:-80,90,100} dwell=${2:-}
  local n_start baseline stage elapsed failed_at="" results="" can_set=1
  n_start=$(ngpus)
  if ! set_limits 100 >/dev/null 2>&1; then
    can_set=0
    stages="current"
    [ -z "$dwell" ] && dwell=86400   # single-stage fallback: 24h soak by default
  fi
  [ -z "$dwell" ] && dwell=3600
  echo "POWER SWEEP: stages=${stages} (% of each GPU's default limit) dwell=${dwell}s/stage gpus=${n_start}"
  if [ "$can_set" -eq 0 ]; then
    echo 'WARN: cannot set power limits (managed pod / no admin rights on GPU).'
    echo "Falling back to a SINGLE ${dwell}s stage at the current limits:"
    nvidia-smi --query-gpu=index,power.limit,power.default_limit --format=csv,noheader 2>/dev/null | sed 's/^/  GPU /'
  fi
  for stage in ${stages//,/ }; do
    baseline=$(new_dropouts)
    echo ''
    echo "=== stage: ${stage} for ${dwell}s ==="
    [ "$can_set" -eq 1 ] && set_limits "$stage"
    bin/gpu_burn -tc "$dwell" >/tmp/gpu_burn.log 2>&1 &
    dma_stress "$dwell"
    python3 ./docker/aer_watch.py 2 < /dev/null | cat &   # pipe forces log mode
    local mon_pid=$!
    elapsed=0
    while [ "$elapsed" -lt "$dwell" ]; do
      sleep 15; elapsed=$((elapsed + 15))
      if [ "$(new_dropouts)" -gt "$baseline" ] || [ "$(ngpus)" -lt "$n_start" ]; then
        failed_at="$stage"
        break
      fi
    done
    kill "$mon_pid" 2>/dev/null
    cleanup
    if [ -n "$failed_at" ]; then
      results="${results}stage ${stage}: FAIL after ${elapsed}s\n"
      echo "FAIL: GPU dropped off the bus at stage ${stage} after ${elapsed}s"
      dmesg 2>/dev/null | grep -E 'Xid|fallen off' | tail -5
      break
    fi
    results="${results}stage ${stage}: PASS ${dwell}s\n"
    echo "PASS: stage ${stage} held for ${dwell}s"
    sleep 10   # settle between stages
  done
  [ "$can_set" -eq 1 ] && set_limits 100 >/dev/null 2>&1   # always leave the cards at their default max
  echo ''
  echo '=== POWER SWEEP RESULT ==='
  printf "%b" "$results"
  if [ -n "$failed_at" ]; then
    echo "Stable ceiling is BELOW stage ${failed_at} - node reboot required to recover the dropped GPU."
  else
    echo "All stages passed - no dropout up to 100% power limit."
  fi
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

case "${1:-sweep}" in
  menu)      menu ;;
  preflight) ./preflight.sh ;;
  watch)     monitor "${2:-3}" ;;
  bandwidth) bin/oclBandwidthTest ;;
  burn)      shift; burn "${1:-300}" "${@:2}" ;;
  dma)       dma_stress "${2:-1800}"; wait ;;
  nvme)      nvme_stress "${2:-1800}"; wait ;;
  full)      full "${2:-1800}" ;;
  sweep)     sweep "${2:-80,90,100}" "${3:-}" ;;
  margin)    bin/Lane-Margining -s "$2" -t "containerized" ;;
  shell)     exec bash ;;
  *)         echo "unknown mode: $1"; exit 1 ;;
esac
