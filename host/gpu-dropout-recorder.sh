#!/bin/bash
# GPU dropout incident recorder — always-on host watchdog.
#
# Records a continuous high-rate per-GPU telemetry ring (DCGM), detects a GPU
# falling off the bus within seconds (Xid via DCGM field 230 + kernel log +
# GPU-count checks), captures a full forensic bundle at that moment, and fires
# a webhook. Designed to stay alive while a GPU is dead: every external call
# is timeout-wrapped, and nvidia-smi (which hangs against dead GPUs) is only
# used as a fallback / secondary check.
#
# Config: /etc/gpu-dropout-recorder.conf (see repo host/gpu-dropout-recorder.conf)
# Test hook: kill -USR1 <pid> forces an incident capture with reason "manual-test".
set -u

CONF=${RECORDER_CONF:-/etc/gpu-dropout-recorder.conf}
[ -f "$CONF" ] && . "$CONF"

DATA_DIR=${DATA_DIR:-/var/log/gpu-recorder}
WEBHOOK_URL=${WEBHOOK_URL:-}
EXPECTED_GPUS=${EXPECTED_GPUS:-}      # empty = auto-baseline at start
SAMPLE_MS=${SAMPLE_MS:-200}           # dcgm sampling period
INTERVAL=${INTERVAL:-5}               # detector loop period, seconds
RING_MAX_MB=${RING_MAX_MB:-100}       # telemetry ring generation size
MAX_BUNDLES=${MAX_BUNDLES:-10}
TAIL_LINES=${TAIL_LINES:-300000}      # telemetry lines kept in a bundle (~2h at 5Hz x 5-8 GPUs)
IPMI_HOST=${IPMI_HOST:-}; IPMI_USER=${IPMI_USER:-}; IPMI_PASS=${IPMI_PASS:-}
VRAM_TOOL=${VRAM_TOOL:-/usr/local/bin/gddr6}   # BAR-level GDDR VRAM hotspot reader (optional)
IPMI_INTERVAL=${IPMI_INTERVAL:-30}
COUNT_CHECK_EVERY=${COUNT_CHECK_EVERY:-6}   # GPU-count check every N detector ticks

# dcgm fields: sm_clk mem_clk throttle mem_temp gpu_temp power pstate gpu_util
# mem_util pcie_replay xid  (xid LAST -> $NF in detection)
DCGM_FIELDS="100,101,112,140,150,155,190,203,204,202,230"

TEL="$DATA_DIR/telemetry.csv"
BMC="$DATA_DIR/bmc.csv"
VRAM="$DATA_DIR/vram.csv"
mkdir -p "$DATA_DIR"

log() { echo "$(date -Is) $*"; }

# ---------- environment probing -------------------------------------------
MODE=none
if command -v dcgmi >/dev/null && timeout 20 dcgmi discovery -l >/dev/null 2>&1; then
  MODE=dcgm
elif command -v nvidia-smi >/dev/null; then
  MODE=smi
fi
log "recorder starting: mode=$MODE data=$DATA_DIR sample=${SAMPLE_MS}ms interval=${INTERVAL}s"
[ "$MODE" = none ] && log "WARNING: neither dcgmi nor nvidia-smi found - kernel-log detection only"

gpu_count() { # cheap, hang-safe GPU count (nvidia-smi -L drops dead GPUs; dcgm does not)
  timeout 20 nvidia-smi -L 2>/dev/null | grep -c '^GPU' || echo 0
}

refresh_gpu_map() { # id -> BDF map from dcgm discovery (works with dead GPUs)
  timeout 20 dcgmi discovery -l 2>/dev/null | awk '
    /^\| [0-9]+ / { id=$2 }
    /PCI Bus ID/  { gsub("00000000:","0000:",$NF); print id","tolower($NF) }' > "$DATA_DIR/gpu-map.txt" 2>/dev/null
}

# ---------- samplers --------------------------------------------------------
sampler_loop() {
  # long-lived stream; per-line append (reopen) so ring rotation is safe
  if [ "$MODE" = dcgm ]; then
    stdbuf -oL dcgmi dmon -e "$DCGM_FIELDS" -d "$SAMPLE_MS" 2>/dev/null
  elif [ "$MODE" = smi ]; then
    nvidia-smi --query-gpu=index,utilization.gpu,utilization.memory,memory.used,temperature.gpu,fan.speed,power.draw,power.limit,clocks.sm,clocks.mem,pstate \
      --format=csv,noheader,nounits -lms 1000 2>/dev/null | sed 's/^/GPU /'
  fi | while IFS= read -r line; do
    case "$line" in
      GPU*) printf '%s %s\n' "${EPOCHREALTIME:-$(date +%s)}" "$line" >> "$TEL" ;;
    esac
  done
}

start_sampler() {
  [ "$MODE" = none ] && return
  sampler_loop &
  SAMPLER_PID=$!
  log "sampler started (pid $SAMPLER_PID)"
}

stop_sampler() {
  [ -n "${SAMPLER_PID:-}" ] && kill "$SAMPLER_PID" 2>/dev/null
  pkill -f 'dcgmi dmon' 2>/dev/null
  pkill -f 'nvidia-smi --query-gpu=.*-lms' 2>/dev/null
}

vram_loop() { # GDDR VRAM hotspot via gddr6 tool (NVML/DCGM report 0 on GeForce)
  [ -x "$VRAM_TOOL" ] || return
  log "VRAM sampler enabled ($VRAM_TOOL)"
  while true; do
    stdbuf -o0 "$VRAM_TOOL" 2>/dev/null | tr "\r" "\n" | while IFS= read -r line; do
      case "$line" in
        Device:*)      printf "# %s %s\n" "$(date +%s)" "$line" >> "$VRAM" ;;
        "VRAM Temps:"*) t=$(echo "$line" | grep -oE "[0-9]+°C" | tr -d "°C" | paste -sd" ")
                        [ -n "$t" ] && printf "%s VRAMHOT %s\n" "${EPOCHREALTIME:-$(date +%s)}" "$t" >> "$VRAM" ;;
      esac
    done
    sleep 10   # tool exited; retry
  done
}

ipmi_loop() {
  local args=()
  if [ -n "$IPMI_HOST" ]; then
    args=(-H "$IPMI_HOST" -U "$IPMI_USER" -P "$IPMI_PASS" -I lanplus)
  elif [ ! -e /dev/ipmi0 ]; then
    return
  fi
  command -v ipmitool >/dev/null || return
  log "IPMI sampler enabled (every ${IPMI_INTERVAL}s)"
  while sleep "$IPMI_INTERVAL"; do
    timeout 25 ipmitool "${args[@]}" sdr elist 2>/dev/null | \
      sed "s/^/$(date -Is) /" >> "$BMC"
  done
}

rotate_ring() {
  local f
  for f in "$TEL" "$BMC" "$VRAM"; do
    [ -f "$f" ] || continue
    if [ "$(stat -c%s "$f" 2>/dev/null || echo 0)" -gt $((RING_MAX_MB * 1024 * 1024)) ]; then
      mv -f "$f" "$f.1"
      log "rotated $(basename "$f")"
    fi
  done
}

# ---------- detection -------------------------------------------------------
START_TS=$(date +%s)   # ring persists across reboots: only trust lines from THIS run
dead_gpus_from_ring() { # GPU ids whose latest XID field ($NF) is numeric >0
  tail -n 400 "$TEL" 2>/dev/null | awk -v t0="$START_TS" '
    $1+0 >= t0 && $2=="GPU" && $NF ~ /^[0-9]+$/ && $NF+0 > 0 { bad[$3]=$NF }
    END { for (g in bad) print g":"bad[g] }'
}

kernel_dropout_count() { dmesg 2>/dev/null | grep -c 'fallen off the bus'; }
kernel_xid_count()     { dmesg 2>/dev/null | grep -c 'NVRM: Xid'; }

# ---------- capture ---------------------------------------------------------
send_webhook() { # send_webhook <reason> <dead> <bundle>
  [ -n "$WEBHOOK_URL" ] || return 0
  local payload
  payload=$(printf '{"text":"GPU DROPOUT on %s: %s (dead: %s) bundle: %s","host":"%s","time":"%s","reason":"%s","dead_gpus":"%s","bundle":"%s"}' \
    "$(hostname)" "$1" "$2" "$3" "$(hostname)" "$(date -Is)" "$1" "$2" "$3")
  local i
  for i in 1 2 3; do
    curl -m 10 -fsS -X POST -H 'Content-Type: application/json' \
      --data "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 && { log "webhook delivered"; return 0; }
    sleep 5
  done
  log "webhook delivery FAILED after 3 attempts"
}

capture_incident() { # capture_incident <reason> <dead-ids>
  local reason=$1 dead=${2:-unknown}
  local dir="$DATA_DIR/incident-$(hostname)-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir"
  log "INCIDENT ($reason, dead: $dead) - capturing to $dir"

  # pre-death telemetry window (the data we never had)
  cat "$TEL.1" "$TEL" 2>/dev/null | tail -n "$TAIL_LINES" > "$dir/telemetry-tail.csv"
  [ -f "$BMC" ] && cat "$BMC.1" "$BMC" 2>/dev/null | tail -n 20000 > "$dir/bmc-tail.csv"
  [ -f "$VRAM" ] && cat "$VRAM.1" "$VRAM" 2>/dev/null | tail -n 20000 > "$dir/vram-tail.csv"

  # DCGM cached snapshot (dead GPUs keep last-known values, e.g. temp at death)
  [ "$MODE" = dcgm ] && timeout 20 dcgmi dmon -e "$DCGM_FIELDS" -c 1 > "$dir/dcgm-snapshot.txt" 2>&1

  # kernel logs (journal may be rotated by AER spam; dmesg as fallback)
  { timeout 30 journalctl -k --no-pager 2>/dev/null | tail -n 5000 || dmesg 2>/dev/null | tail -n 5000; } > "$dir/kernel.log"
  grep -E 'Xid|fallen|NVRM|AER|BadTLP|BadDLLP' "$dir/kernel.log" > "$dir/kernel-gpu.log" 2>/dev/null

  # AER counters (reset on reboot - must be captured now), full per-type dump
  local d f
  for d in /sys/bus/pci/devices/*; do
    for f in aer_dev_correctable aer_dev_nonfatal aer_dev_fatal; do
      [ -f "$d/$f" ] || continue
      echo "== $d/$f =="; cat "$d/$f"
    done
  done > "$dir/aer-counters.txt" 2>/dev/null

  # PCI state: topology + every NVIDIA function + its root port (captures 7f)
  timeout 30 lspci -tv > "$dir/lspci-tree.txt" 2>&1
  for d in /sys/bus/pci/devices/*; do
    [ "$(cat "$d/vendor" 2>/dev/null)" = 0x10de ] || continue
    local bdf port
    bdf=$(basename "$d")
    port=$(basename "$(dirname "$(readlink -f "$d")")")
    timeout 20 lspci -s "$bdf" -vv; echo; timeout 20 lspci -s "$port" -vv; echo "----"
  done > "$dir/lspci.txt" 2>&1

  # driver view + physical card map (for the swap experiment)
  timeout 20 nvidia-smi > "$dir/nvidia-smi.txt" 2>&1
  timeout 20 nvidia-smi --query-gpu=index,pci.bus_id,serial,uuid --format=csv > "$dir/gpu-map.csv" 2>&1
  refresh_gpu_map; cp "$DATA_DIR/gpu-map.txt" "$dir/dcgm-gpu-map.txt" 2>/dev/null

  # NVIDIA case file (safe-mode: plain mode can hang against a dead GPU)
  if command -v nvidia-bug-report.sh >/dev/null; then
    ( cd "$dir" && timeout 300 nvidia-bug-report.sh --safe-mode >/dev/null 2>&1 )
  fi

  {
    printf '{"host":"%s","time":"%s","boot":"%s","reason":"%s","dead_gpus":"%s",' \
      "$(hostname)" "$(date -Is)" "$(uptime -s)" "$reason" "$dead"
    printf '"driver":"%s","recorder_mode":"%s"}\n' \
      "$(grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' /proc/driver/nvidia/version 2>/dev/null | head -1)" "$MODE"
  } > "$dir/meta.json"

  # prune old bundles
  ls -dt "$DATA_DIR"/incident-* 2>/dev/null | tail -n +$((MAX_BUNDLES + 1)) | xargs -r rm -rf

  send_webhook "$reason" "$dead" "$dir"
  log "incident bundle complete: $dir"
}

# ---------- main ------------------------------------------------------------
FORCE_CAPTURE=0
trap 'FORCE_CAPTURE=1' USR1
trap 'stop_sampler; exit 0' TERM INT

start_sampler
ipmi_loop &
vram_loop &
refresh_gpu_map

BASE_DROPS=$(kernel_dropout_count)
BASE_XIDS=$(kernel_xid_count)
if [ -n "$EXPECTED_GPUS" ]; then BASE_COUNT=$EXPECTED_GPUS; else BASE_COUNT=$(gpu_count); fi
log "baseline: gpus=$BASE_COUNT kernel_dropouts=$BASE_DROPS kernel_xids=$BASE_XIDS"

ARMED=1
sleep 5
# already-dead check at startup: alert once, stay disarmed until it clears
startup_dead=$(dead_gpus_from_ring)
if [ -n "$startup_dead" ]; then
  capture_incident "already-dead-at-start" "$startup_dead"
  ARMED=0
fi

TICK=0
LAST_SIZE=0
STALL=0
STALL_FIRED=0
CLEAR=0
while true; do
  sleep "$INTERVAL"
  TICK=$((TICK + 1))
  rotate_ring

  reason=""; dead=""

  if [ "$FORCE_CAPTURE" = 1 ]; then
    reason="manual-test"; dead="none"; FORCE_CAPTURE=0
  fi

  # 1. XID in the telemetry stream (primary, sub-second detection source)
  if [ -z "$reason" ]; then
    dead=$(dead_gpus_from_ring)
    if [ -n "$dead" ] && [ "$ARMED" = 1 ]; then reason="dcgm-xid"; fi
  fi

  # 2. kernel log counters (immune to journal rotation)
  if [ -z "$reason" ] && [ "$ARMED" = 1 ]; then
    d=$(kernel_dropout_count); x=$(kernel_xid_count)
    if [ "$d" -gt "$BASE_DROPS" ] || [ "$x" -gt "$BASE_XIDS" ]; then
      reason="kernel-log"; BASE_DROPS=$d; BASE_XIDS=$x
    fi
  fi

  # 3. GPU count via nvidia-smi (every Nth tick; dead GPUs vanish from -L).
  # Baseline auto-raises: if the service started while a GPU was dead and the
  # card later recovers (reset/reboot), the higher count becomes the new floor.
  if [ -z "$reason" ] && [ "$ARMED" = 1 ] && [ $((TICK % COUNT_CHECK_EVERY)) = 0 ] && [ "$MODE" != none ]; then
    c=$(gpu_count)
    if [ "$c" -gt "$BASE_COUNT" ]; then
      BASE_COUNT=$c
      log "GPU-count baseline raised to $c"
    elif [ "$c" -lt "$BASE_COUNT" ] && [ "$c" -ge 0 ]; then
      reason="gpu-count($c<$BASE_COUNT)"
    fi
  fi

  # 4. sampler stall -> restart; 3 consecutive stalls while armed = incident.
  # STALL_FIRED latch: fire at most once until telemetry actually flows again
  # (prevents bundle spam on hosts where the sampler can never produce data).
  if [ "$MODE" != none ]; then
    sz=$(stat -c%s "$TEL" 2>/dev/null || echo 0)
    if [ "$sz" = "$LAST_SIZE" ]; then
      STALL=$((STALL + 1))
      if ! kill -0 "${SAMPLER_PID:-0}" 2>/dev/null; then stop_sampler; start_sampler; fi
      if [ "$STALL" -ge 3 ] && [ "$ARMED" = 1 ] && [ -z "$reason" ] \
         && [ "$STALL_FIRED" = 0 ] && [ "$BASE_COUNT" -gt 0 ]; then
        reason="sampler-stalled"; STALL_FIRED=1; stop_sampler; start_sampler
      fi
    else
      STALL=0; STALL_FIRED=0
    fi
    LAST_SIZE=$sz
  fi

  if [ -n "$reason" ]; then
    capture_incident "$reason" "${dead:-unknown}"
    [ "$reason" = "manual-test" ] || ARMED=0
  fi

  # re-arm once the dead signature clears (post power-cycle recovery).
  # Require CLEAR_NEEDED consecutive clean ticks: a single clean read can be a
  # race with ring rotation (fresh file briefly missing dead-GPU rows), which
  # caused re-arm/re-fire flapping every rotation period.
  if [ "$ARMED" = 0 ]; then
    if [ -z "$(dead_gpus_from_ring)" ] && { [ "$MODE" = none ] || [ "$(gpu_count)" -ge "$BASE_COUNT" ]; }; then
      CLEAR=$((CLEAR + 1))
      if [ "$CLEAR" -ge "${CLEAR_NEEDED:-6}" ]; then
        ARMED=1; CLEAR=0
        BASE_DROPS=$(kernel_dropout_count); BASE_XIDS=$(kernel_xid_count)
        log "re-armed: GPUs recovered"
      fi
    else
      CLEAR=0
    fi
  fi
done
