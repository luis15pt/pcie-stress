#!/bin/bash
# Junction-temperature heat screen - the reference load for a service claim.
#
# Why a defined load matters: junction runs 10-20C above core, and an existing
# incident bundle measured core at 90C under gpu_burn, so ANY 5090 under heavy
# load will legitimately sit at 100-110C junction. The vendor's "over 100C is
# due for service" figure therefore only means something at a stated load and
# inlet temperature. A 103C reading during an arbitrary stress test is a weak
# claim; 103C under this documented, repeatable soak is a strong one.
#
# THIS SCRIPT STOPS TENANT-FACING SERVICES (runpod, amazon-ssm-agent) so the
# load container is not killed mid-run, and restarts them on ANY exit path
# including Ctrl-C. It refuses to run without --confirm.
#
# Usage:
#   sudo ./gpu-heat-screen.sh --confirm [--method pytorch|gpuburn]
#                             [--duration SECS] [--crit 100]
#   sudo ./gpu-heat-screen.sh --dry-run        # show the plan, change nothing
#
# Exit: 0 all cards below CRIT, 2 at least one at/above CRIT, 1 setup failure.
set -u

METHOD=pytorch
DURATION=1800
CRIT=${JUNCTION_CRIT:-100}
CONFIRM=0
DRY=0
POLL=5
IMAGE_PYTORCH=${IMAGE_PYTORCH:-runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404}
IMAGE_GPUBURN=${IMAGE_GPUBURN:-ghcr.io/luis15pt/pcie-stress:latest}
NAME=gpu-heat-screen
SUPPRESS=${JUNCTION_SUPPRESS_FILE:-/run/gpu-junction-suppress}
OUTDIR=${OUTDIR:-/var/log/gpu-recorder/heat-screen-$(date +%Y%m%d-%H%M%S)}
CHECK=${CHECK:-/usr/local/bin/gpu-junction-check.sh}
STOP_SERVICES=${STOP_SERVICES:-runpod amazon-ssm-agent}

while [ $# -gt 0 ]; do
  case "$1" in
    --confirm)  CONFIRM=1 ;;
    --dry-run)  DRY=1 ;;
    --method)   METHOD=${2:?}; shift ;;
    --duration) DURATION=${2:?}; shift ;;
    --crit)     CRIT=${2:?}; shift ;;
    --poll)     POLL=${2:?}; shift ;;
    --help|-h)  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 64 ;;
  esac
  shift
done
case "$METHOD" in pytorch|gpuburn) ;; *) echo "--method must be pytorch or gpuburn" >&2; exit 64 ;; esac

log() { echo "$(date -Is) $*"; }

plan() {
  cat << PLAN
Heat screen plan
  method        : $METHOD ($([ "$METHOD" = pytorch ] && echo "$IMAGE_PYTORCH" || echo "$IMAGE_GPUBURN"))
  duration      : ${DURATION}s
  service thresh: ${CRIT}C junction
  poll          : every ${POLL}s
  results       : $OUTDIR
  WILL STOP     : $STOP_SERVICES   (restarted on every exit path)
  WILL SUPPRESS : junction alerting for the run, via $SUPPRESS
                  (expires automatically; the recorder keeps SAMPLING throughout)
PLAN
}

if [ "$DRY" = 1 ]; then plan; echo; echo "dry run: nothing was changed."; exit 0; fi
if [ "$CONFIRM" != 1 ]; then
  plan
  echo ""
  echo "REFUSING: this stops tenant-facing services. Re-run with --confirm." >&2
  exit 64
fi
[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0 --confirm" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker required" >&2; exit 1; }
[ -x "$CHECK" ] || { echo "missing $CHECK - install host/gpu-junction-check.sh" >&2; exit 1; }

mkdir -p "$OUTDIR"
STOPPED=""

restore() {
  local rc=$?
  set +u
  log "restoring state"
  docker rm -f "$NAME" >/dev/null 2>&1
  rm -f "$SUPPRESS"
  for s in $STOPPED; do
    log "restarting $s"
    systemctl start "$s" >/dev/null 2>&1 || log "WARNING: failed to start $s - START IT MANUALLY"
  done
  # Trap covers INT/TERM as well as EXIT, so an interrupted run never leaves
  # tenant services down or thermal alerting suppressed.
  exit $rc
}
trap restore EXIT INT TERM

plan | tee "$OUTDIR/plan.txt"

# suppression expires on its own even if this script is killed -9
echo $(( $(date +%s) + DURATION + 300 )) > "$SUPPRESS"
log "junction alerting suppressed until $(date -d @"$(cat "$SUPPRESS")" -Is 2>/dev/null || cat "$SUPPRESS")"

for s in $STOP_SERVICES; do
  if systemctl is-active --quiet "$s" 2>/dev/null; then
    log "stopping $s"
    systemctl stop "$s" && STOPPED="$STOPPED $s"
  fi
done

log "baseline (idle) junction:"
"$CHECK" | tee "$OUTDIR/baseline.txt" || true

# --- the load ---------------------------------------------------------------
if [ "$METHOD" = pytorch ]; then
  # Reconstruction of the vendor's screening recipe: concurrent small-kernel
  # "hammer" launches, sustained FP32 matmul, and a large resident VRAM
  # allocation, so the die, the memory controller and the modules all heat at
  # once. This is the load the 100C figure should be read against.
  cat > "$OUTDIR/load.py" << 'PY'
import threading, torch, time

def hammer(dev):
    a = torch.randn(64, 64, device=dev)
    while True:
        for _ in range(2000):
            a = a * 1.0001
        torch.cuda.synchronize(dev)

def fp32_load(dev):
    n = 8192
    a = torch.randn(n, n, device=dev)
    b = torch.randn(n, n, device=dev)
    while True:
        c = a @ b
        a = c / (c.abs().mean() + 1e-6)
        torch.cuda.synchronize(dev)

def vram_load(dev):
    # keep a large resident footprint so the GDDR modules stay exercised
    free, total = torch.cuda.mem_get_info(dev)
    keep, blocks = int(free * 0.55), []
    try:
        while sum(b.numel() * 4 for b in blocks) < keep:
            blocks.append(torch.randn(1 << 26, device=dev))
    except RuntimeError:
        pass
    while True:
        for b in blocks:
            b.mul_(1.00001)
        torch.cuda.synchronize(dev)
        time.sleep(0.01)

for i in range(torch.cuda.device_count()):
    d = torch.device("cuda", i)
    for fn in (hammer, fp32_load, vram_load):
        threading.Thread(target=fn, args=(d,), daemon=True).start()
print("load running on %d GPU(s)" % torch.cuda.device_count(), flush=True)
while True:
    time.sleep(3600)
PY
  log "starting pytorch load ($IMAGE_PYTORCH)"
  docker run -d --name "$NAME" --gpus all --shm-size=8g \
    -v "$OUTDIR/load.py:/load.py:ro" "$IMAGE_PYTORCH" python /load.py \
    > "$OUTDIR/container-id.txt" 2>&1 || { log "docker run FAILED"; cat "$OUTDIR/container-id.txt"; exit 1; }
else
  log "starting gpu_burn load ($IMAGE_GPUBURN)"
  docker run -d --name "$NAME" --privileged --gpus all \
    "$IMAGE_GPUBURN" full "$DURATION" \
    > "$OUTDIR/container-id.txt" 2>&1 || { log "docker run FAILED"; cat "$OUTDIR/container-id.txt"; exit 1; }
fi

sleep 20
if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
  log "load container exited immediately:"; docker logs "$NAME" 2>&1 | tail -20; exit 1
fi

# --- poll -------------------------------------------------------------------
CSV="$OUTDIR/samples.csv"
echo "epoch,pci_bus_id,junction_c,core_c,gddr_c,valid,throttle" > "$CSV"
END=$(( $(date +%s) + DURATION ))
log "soaking for ${DURATION}s; per-GPU maxima recorded to $CSV"
while [ "$(date +%s)" -lt "$END" ]; do
  now=$(date +%s)
  "$CHECK" --json 2>/dev/null | python3 -c '
import json, sys, os
now = os.environ["NOW"]
try:
    rows = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for r in rows:
    if r.get("dead"):
        continue
    print("%s,%s,%s,%s,%s,%s," % (now, r["pci_bus_id"], r["junction_c"],
          r["core_gputemps_c"], r["gddr_max_c"], 1 if r["valid"] else 0))
' NOW="$now" >> "$CSV" 2>/dev/null
  # V6 corroboration: if HW-THERMAL asserts, junction should be at maximum
  grep -h "^DCGM_FI_DEV_CLOCKS_THROTTLE_REASON" /metrics.txt 2>/dev/null \
    | awk -v ts="$now" '{print ts",throttle,"$NF}' >> "$OUTDIR/throttle.csv"
  remain=$(( END - $(date +%s) ))
  printf "\r  %ds remaining, hottest junction so far: %sC   " \
    "$remain" "$(awk -F, 'NR>1 && $6==1 && $3!="null" && $3+0>m{m=$3+0} END{print (m?m:"?")}' "$CSV")"
  sleep "$POLL"
done
echo ""

log "stopping load"
docker stop -t 20 "$NAME" >/dev/null 2>&1
docker logs "$NAME" > "$OUTDIR/container.log" 2>&1

# --- verdict ----------------------------------------------------------------
log "cooldown 30s"
sleep 30
"$CHECK" > "$OUTDIR/after.txt" 2>&1 || true

RC=0
{
  echo ""
  echo "================ HEAT SCREEN VERDICT ================"
  printf "host       : %s\n" "$(hostname)"
  printf "method     : %s   duration: %ss\n" "$METHOD" "$DURATION"
  printf "threshold  : junction >= %sC under this load = due for service\n\n" "$CRIT"
  printf "%-14s %9s %9s %8s %8s  %s\n" PCI PEAK_JUNC PEAK_CORE PEAK_GDDR SAMPLES VERDICT
  awk -F, -v crit="$CRIT" '
    NR>1 && $6==1 {
      if ($3 != "null" && $3+0 > pj[$2]) pj[$2]=$3+0
      if ($4 != "null" && $4+0 > pc[$2]) pc[$2]=$4+0
      if ($5 != "null" && $5+0 > pg[$2]) pg[$2]=$5+0
      n[$2]++
    }
    END {
      bad = 0
      for (b in n) {
        v = (pj[b] >= crit) ? "SERVICE" : "OK"
        if (pj[b] >= crit) bad = 1
        printf "%-14s %9s %9s %8s %8s  %s\n", b, pj[b], pc[b], pg[b], n[b], v
      }
      exit bad
    }' "$CSV" || RC=2
  echo ""
  if [ -s "$OUTDIR/throttle.csv" ]; then
    printf "throttle reasons seen (nonzero = HW protection asserted): %s\n" \
      "$(awk -F, '$3+0>0{c++} END{print c+0}' "$OUTDIR/throttle.csv") samples"
  fi
  echo "full results: $OUTDIR"
  if [ "$RC" = 2 ]; then
    echo ""
    echo "ACTION: cards marked SERVICE sustained >=${CRIT}C junction under the"
    echo "reference load. Quote this directory (samples.csv + plan.txt) in the"
    echo "service claim - it documents the load, not just the temperature."
  fi
  echo "====================================================="
} | tee "$OUTDIR/verdict.txt"

exit "$RC"
