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
PSU_URL=${PSU_URL:-http://localhost:9101/metrics}  # octoserver PSU exporter (all PSUs incl. ones the BMC cannot see)
PSU_INTERVAL=${PSU_INTERVAL:-60}
IPMI_INTERVAL=${IPMI_INTERVAL:-30}
COUNT_CHECK_EVERY=${COUNT_CHECK_EVERY:-6}   # GPU-count check every N detector ticks

# ---- junction (hotspot) thermal watch -------------------------------------
# Vendor guidance: a 5090 sustained over 100C junction is due for service. No
# NVIDIA interface reports junction, so it comes from the vram-metrics pipeline
# (/metrics.txt), which already applies the whole validity gate. We read that
# file rather than scraping :9500 over HTTP or spawning our own gputemps: one
# source of truth, no third BAR reader, and it keeps working when the scrape
# path is broken - which is disproportionately likely while a card is cooking.
METRICS_FILE=${METRICS_FILE:-/metrics.txt}
JUNCTION_TOOL=${JUNCTION_TOOL:-/usr/local/bin/gputemps}
JUNCTION_FILE_STALE=${JUNCTION_FILE_STALE:-60}  # then fall back to the tool directly
JUNCTION_SAMPLE=${JUNCTION_SAMPLE:-2}      # matches the merger's write period
JUNCTION_WARN=${JUNCTION_WARN:-95}
JUNCTION_CRIT=${JUNCTION_CRIT:-100}
JUNCTION_CLEAR_HYST=${JUNCTION_CLEAR_HYST:-3}
# A 5090 moves ~10C/s at load onset, so a 1s spike is not an incident.
JUNCTION_SUSTAIN=${JUNCTION_SUSTAIN:-6}    # ticks above threshold before firing
JUNCTION_CLEAR_TICKS=${JUNCTION_CLEAR_TICKS:-12}
JUNCTION_RENOTIFY=${JUNCTION_RENOTIFY:-3600}
MAX_THERMAL_SNAPS=${MAX_THERMAL_SNAPS:-20}

# dcgm fields: sm_clk mem_clk throttle mem_temp gpu_temp power pstate gpu_util
# mem_util pcie_replay xid  (xid LAST -> $NF in detection)
DCGM_FIELDS="100,101,112,140,150,155,190,203,204,202,230"

TEL="$DATA_DIR/telemetry.csv"
BMC="$DATA_DIR/bmc.csv"
VRAM="$DATA_DIR/vram.csv"
PSU="$DATA_DIR/psu.csv"
JUNCTION="$DATA_DIR/junction.csv"
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

refresh_gpu_map() { # dcgm entity id -> BDF -> UUID (works with dead GPUs)
  # dcgmi prints a box-drawn table, so the BDF is NOT the last field - $NF is the
  # closing "|". Extracting positionally produced "0,|" for every GPU, which broke
  # every bundle's gpu map. Match the values by regex instead.
  timeout 20 dcgmi discovery -l 2>/dev/null | awk '
    /^\| *[0-9]+ +\|/ { id=$2 }
    /PCI Bus ID:/ {
      if (match($0, /[0-9A-Fa-f]{8}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-9]/)) {
        bdf = substr($0, RSTART, RLENGTH); sub(/^00000000:/, "0000:", bdf); bdf = tolower(bdf)
      }
    }
    /Device UUID:/ {
      if (match($0, /GPU-[0-9a-fA-F-]+/) && bdf != "") {
        print id "," bdf "," substr($0, RSTART, RLENGTH)
      }
    }' > "$DATA_DIR/gpu-map.txt" 2>/dev/null
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

metrics_loop() { # VRAM + junction, both from the merged exposition
  # Replaces the old vram_loop, which ran its OWN gddr6 process and wrote every
  # reading unfiltered - so Juno's dead GPU logged a constant 120C into
  # vram.csv and corrupted post-incident thermal analysis. Reading /metrics.txt
  # instead inherits the validity gate, removes one of three concurrent BAR
  # readers and one duplicate parser, gains junction, and drops a locale hazard
  # (the old parser depended on the UTF-8 degree sign with no LC_ALL set).
  # It also keys every row by PCI address, so the vram-order.txt positional
  # guesswork is gone.
  log "metrics sampler enabled ($METRICS_FILE every ${JUNCTION_SAMPLE}s)"
  while true; do
    junction_samples | while read -r bdf j ctool cnvml vmax vmean valid reason; do
      [ -n "$bdf" ] || continue
      printf "%s JUNCTION %s %s %s %s %s %s\n" \
        "${EPOCHREALTIME:-$(date +%s)}" "$bdf" "$j" "$ctool" "$cnvml" "$valid" "$reason" >> "$JUNCTION"
      [ "$vmax" = "NaN" ] || printf "%s VRAM %s %s %s\n" \
        "${EPOCHREALTIME:-$(date +%s)}" "$bdf" "$vmax" "$vmean" >> "$VRAM"
    done
    sleep "$JUNCTION_SAMPLE"
  done
}

junction_samples() { # -> "bdf junction core_tool core_nvml vram_max vram_mean valid reason"
  local age=999999 now
  now=$(date +%s)
  if [ -f "$METRICS_FILE" ]; then
    age=$(( now - $(stat -c%Y "$METRICS_FILE" 2>/dev/null || echo 0) ))
  fi
  if [ -f "$METRICS_FILE" ] && [ "$age" -le "$JUNCTION_FILE_STALE" ]; then
    awk '
      function lbl(s, key,   m) {
        if (match(s, key "=\"[^\"]*\"")) {
          m = substr(s, RSTART, RLENGTH); sub(/^[^"]*"/, "", m); sub(/"$/, "", m)
          return m
        }
        return ""
      }
      /^gpu_junction_temp_celsius\{/        { b=lbl($0,"pci_bus_id"); j[b]=$NF; seen[b]=1 }
      /^gpu_junction_temp_valid\{/          { b=lbl($0,"pci_bus_id"); v[b]=$NF; seen[b]=1 }
      /^gpu_core_temp_celsius\{.*source="gputemps"\}/ { b=lbl($0,"pci_bus_id"); ct[b]=$NF }
      /^gpu_core_temp_celsius\{.*source="nvml"\}/     { b=lbl($0,"pci_bus_id"); cn[b]=$NF }
      /^gddr6_vram_temp_max_celsius\{/      { b=lbl($0,"pci_bus_id"); vx[b]=$NF }
      /^gddr6_vram_temp_mean_celsius\{/     { b=lbl($0,"pci_bus_id"); vm[b]=$NF }
      /^gpu_junction_invalid_reason\{/      { b=lbl($0,"pci_bus_id"); r[b]=lbl($0,"reason") }
      END {
        for (b in seen) printf "%s %s %s %s %s %s %s %s\n", b,
          (b in j ? j[b] : "NaN"), (b in ct ? ct[b] : "NaN"),
          (b in cn ? cn[b] : "NaN"), (b in vx ? vx[b] : "NaN"),
          (b in vm ? vm[b] : "NaN"), (b in v ? v[b] : 0),
          (b in r ? r[b] : "-")
      }' "$METRICS_FILE" 2>/dev/null
    return 0
  fi
  # Degraded fallback: the pipeline is down, so ask the tool directly. This
  # path can only label GPUs by NVML index - enough to raise an alarm, not
  # enough for per-card attribution, so it is explicitly marked idx<N>.
  [ -x "$JUNCTION_TOOL" ] || return 0
  command -v python3 >/dev/null || return 0
  timeout 30 "$JUNCTION_TOOL" --json --once 2>/dev/null | python3 -c '
import json, sys
for line in sys.stdin:
    try:
        o = json.loads(line)
    except ValueError:
        continue
    for g in o.get("gpus", []):
        j, c = g.get("junction"), g.get("core")
        if j is None or c is None or j <= 0 or j < c - 1 or j > 125:
            print("idx%s NaN %s NaN NaN NaN 0 fallback_rejected" % (g.get("index"), c))
        else:
            print("idx%s %s %s NaN NaN NaN 1 fallback" % (g.get("index"), j, c))
' 2>/dev/null
}

psu_loop() { # per-PSU output/status from the local exporter (BMC often exposes only a subset)
  curl -s --max-time 30 "$PSU_URL" >/dev/null 2>&1 || return
  log "PSU sampler enabled ($PSU_URL every ${PSU_INTERVAL}s)"
  while true; do
    curl -s --max-time 30 "$PSU_URL" 2>/dev/null | awk -v ts="$(date +%s)" '
      /^octoserver_psu_(output_power_watts|output_voltage_volts|status_ok|input_voltage_volts|temperature_celsius|fan_speed_rpm)\{/ {
        m=$0; sub(/\{.*/,"",m); sub(/^octoserver_psu_/,"",m)
        p=""; if (match($0, /psu="[^"]+"/)) { p=substr($0,RSTART+5,RLENGTH-6) }
        s=""; if (match($0, /status="[^"]+"/)) { s=substr($0,RSTART+8,RLENGTH-9) }
        print ts, "PSU", p, m, $NF, s
      }' >> "$PSU"
    sleep "$PSU_INTERVAL"
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
  for f in "$TEL" "$BMC" "$VRAM" "$PSU" "$JUNCTION"; do
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
_post_webhook() { # _post_webhook <payload>
  [ -n "$WEBHOOK_URL" ] || return 0
  local i
  for i in 1 2 3; do
    curl -m 10 -fsS -X POST -H 'Content-Type: application/json' \
      --data "$1" "$WEBHOOK_URL" >/dev/null 2>&1 && { log "webhook delivered"; return 0; }
    sleep 5
  done
  log "webhook delivery FAILED after 3 attempts"
}

send_webhook() { # send_webhook <reason> <dead> <bundle>
  # Payload deliberately unchanged: an existing consumer parses these fields.
  # Thermal alerts get their own function rather than a "kind" branch in here,
  # so no future edit can accidentally alter the dropout contract.
  [ -n "$WEBHOOK_URL" ] || return 0
  local payload
  payload=$(printf '{"text":"GPU DROPOUT on %s: %s (dead: %s) bundle: %s","host":"%s","time":"%s","reason":"%s","dead_gpus":"%s","bundle":"%s"}' \
    "$(hostname)" "$1" "$2" "$3" "$(hostname)" "$(date -Is)" "$1" "$2" "$3")
  _post_webhook "$payload"
}

send_thermal_webhook() { # <level> <bdf> <junction> <core> <peak> <snapshot>
  [ -n "$WEBHOOK_URL" ] || return 0
  local payload
  payload=$(printf '{"text":"GPU JUNCTION %s on %s: %s at %sC (core %sC, episode peak %sC) - vendor threshold: sustained >=100C is a service case. snapshot: %s","host":"%s","time":"%s","kind":"thermal","level":"%s","pci_bus_id":"%s","junction_c":"%s","core_c":"%s","peak_c":"%s","snapshot":"%s"}' \
    "$1" "$(hostname)" "$2" "$3" "$4" "$5" "$6" \
    "$(hostname)" "$(date -Is)" "$1" "$2" "$3" "$4" "$5" "$6")
  _post_webhook "$payload"
}

capture_incident() { # capture_incident <reason> <dead-ids>
  local reason=$1 dead=${2:-unknown}
  local dir="$DATA_DIR/incident-$(hostname)-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir"
  log "INCIDENT ($reason, dead: $dead) - capturing to $dir"

  # pre-death telemetry window (the data we never had)
  cat "$TEL.1" "$TEL" 2>/dev/null | tail -n "$TAIL_LINES" > "$dir/telemetry-tail.csv"
  [ -f "$BMC" ] && cat "$BMC.1" "$BMC" 2>/dev/null | tail -n 20000 > "$dir/bmc-tail.csv"
  [ -f "$PSU" ] && cat "$PSU.1" "$PSU" 2>/dev/null | tail -n 20000 > "$dir/psu-tail.csv"
  [ -f "$VRAM" ] && cat "$VRAM.1" "$VRAM" 2>/dev/null | tail -n 20000 > "$dir/vram-tail.csv"
  [ -f "$JUNCTION" ] && cat "$JUNCTION.1" "$JUNCTION" 2>/dev/null | tail -n 20000 > "$dir/junction-tail.csv"

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


latched_xid_bdfs() { # PCI addresses of GPUs with a latched XID (i.e. dead)
  # A card that has fallen off the bus keeps reporting its temperature at the
  # moment of death - stale, frozen and often high - so it would alert forever.
  # This is the same class of bug that once held the chassis fans at 44% off a
  # dead GPU's cached 82C. Needs the DCGM-entity -> BDF map, which is why
  # refresh_gpu_map() had to be fixed first.
  local ids id bdf
  ids=$(dead_gpus_from_ring | cut -d: -f1)
  [ -n "$ids" ] || return 0
  for id in $ids; do
    bdf=$(awk -F, -v i="$id" '$1==i {print $2}' "$DATA_DIR/gpu-map.txt" 2>/dev/null)
    [ -n "$bdf" ] && printf "%s\n" "$bdf"
  done
}

prune_thermal_snaps() {
  local n
  n=$(ls -1d "$DATA_DIR"/thermal-* 2>/dev/null | wc -l)
  [ "$n" -gt "$MAX_THERMAL_SNAPS" ] || return 0
  ls -1dt "$DATA_DIR"/thermal-* 2>/dev/null | tail -n +$((MAX_THERMAL_SNAPS + 1)) \
    | xargs -r rm -rf
}

THERMAL_SNAP=""
capture_thermal_snapshot() { # <level> <bdf> <junction>; result in $THERMAL_SNAP
  # Returns via a global rather than stdout on purpose: log() writes to stdout,
  # so capturing this function with $(...) swallowed its own log line into the
  # webhook payload AND kept it out of the journal.
  # Deliberately NOT capture_incident(): that runs nvidia-bug-report.sh (up to
  # 300s) and its caller disarms dropout detection. Disarming the dropout
  # watchdog because a card got hot would be a serious regression, so this is a
  # light, fast, separately-pruned capture.
  local dir="$DATA_DIR/thermal-$(hostname)-$(date +%Y%m%d-%H%M%S)-${2//:/_}"
  mkdir -p "$dir"
  log "THERMAL $1 ($2 at $3C) - snapshot to $dir"
  cat "$JUNCTION.1" "$JUNCTION" 2>/dev/null | tail -n 5000 > "$dir/junction-tail.csv"
  cat "$TEL.1" "$TEL" 2>/dev/null | tail -n 20000 > "$dir/telemetry-tail.csv"
  timeout 25 dcgmi dmon -e "$DCGM_FIELDS" -c 1 > "$dir/dcgm-now.txt" 2>&1
  timeout 25 nvidia-smi -q -d TEMPERATURE,POWER,PERFORMANCE > "$dir/nvidia-smi-temps.txt" 2>&1
  cp "$METRICS_FILE" "$dir/metrics.txt" 2>/dev/null
  cp "$DATA_DIR/gpu-map.txt" "$dir/dcgm-gpu-map.txt" 2>/dev/null
  printf '{"host":"%s","time":"%s","kind":"thermal","level":"%s","pci_bus_id":"%s","junction_c":"%s"}\n' \
    "$(hostname)" "$(date -Is)" "$1" "$2" "$3" > "$dir/meta.json"
  prune_thermal_snaps
  THERMAL_SNAP="$dir"
}

# JSTATE = last level REPORTED (drives dedupe); JLVL = last level OBSERVED
# (drives the sustain streak). They are distinct: a GPU can sit observed-warn
# for hours while crit remains the last thing reported.
declare -A JSTATE JSTREAK JCLEAR JLAST JPEAK JLVL
junction_check() {
  local now latched bdf j ctool cnvml vmax vmean valid reason
  local lvl thr prev streak
  now=$(date +%s)
  latched=" $(latched_xid_bdfs | paste -sd' ' -) "
  while read -r bdf j ctool cnvml vmax vmean valid reason; do
    [ -n "${bdf:-}" ] || continue
    case "$latched" in *" $bdf "*) continue ;; esac
    [ "${valid:-0}" = "1" ] || continue
    case "$j" in ''|*[!0-9]*) continue ;; esac

    if   [ "$j" -ge "$JUNCTION_CRIT" ]; then lvl=crit; thr=$JUNCTION_CRIT
    elif [ "$j" -ge "$JUNCTION_WARN" ]; then lvl=warn; thr=$JUNCTION_WARN
    else lvl=ok; thr=0
    fi
    prev=${JSTATE[$bdf]:-ok}

    # episode peak, for the report
    if [ "$lvl" != ok ] && [ "$j" -gt "${JPEAK[$bdf]:-0}" ]; then JPEAK[$bdf]=$j; fi

    if [ "$lvl" = ok ]; then
      JSTREAK[$bdf]=0; JLVL[$bdf]=ok
      if [ "$prev" != ok ]; then
        # hysteresis: must fall clearly below the threshold that fired, for a
        # sustained period, before the episode is declared over
        local clear_at=$JUNCTION_WARN
        [ "$prev" = crit ] && clear_at=$JUNCTION_CRIT
        if [ "$j" -le $(( clear_at - JUNCTION_CLEAR_HYST )) ]; then
          JCLEAR[$bdf]=$(( ${JCLEAR[$bdf]:-0} + 1 ))
          if [ "${JCLEAR[$bdf]}" -ge "$JUNCTION_CLEAR_TICKS" ]; then
            log "EVENT thermal-recovered $bdf junction=${j}C (episode peak ${JPEAK[$bdf]:-?}C, was $prev)"
            JSTATE[$bdf]=ok; JCLEAR[$bdf]=0; JPEAK[$bdf]=0; JLAST[$bdf]=0
          fi
        else
          JCLEAR[$bdf]=0
        fi
      fi
      continue
    fi

    JCLEAR[$bdf]=0
    # The streak is per-level, reset whenever the observed level changes.
    # Carrying it across levels would let a single-tick excursion from a long
    # warm spell (97C -> 103C for one sample) page immediately, which is the
    # precise spike the sustain window exists to absorb.
    if [ "${JLVL[$bdf]:-}" != "$lvl" ]; then
      JSTREAK[$bdf]=0
      JLVL[$bdf]=$lvl
    fi
    streak=$(( ${JSTREAK[$bdf]:-0} + 1 ))
    JSTREAK[$bdf]=$streak

    # escalation only, never on repeats: fire when the level rises above what
    # was last reported and the reading has held for the sustain window
    local escalated=0
    if [ "$streak" -ge "$JUNCTION_SUSTAIN" ]; then
      if [ "$prev" = ok ] && [ "$lvl" = warn ]; then escalated=1
      elif [ "$prev" != crit ] && [ "$lvl" = crit ]; then escalated=1
      elif [ "$lvl" = crit ] && [ "$prev" = crit ] \
           && [ $(( now - ${JLAST[$bdf]:-0} )) -ge "$JUNCTION_RENOTIFY" ]; then
        escalated=2   # still critical, hourly reminder at most
      fi
    fi
    if [ "$escalated" != 0 ]; then
      capture_thermal_snapshot "$lvl" "$bdf" "$j"
      send_thermal_webhook "$lvl" "$bdf" "$j" "$ctool" "${JPEAK[$bdf]:-$j}" "$THERMAL_SNAP"
      JSTATE[$bdf]=$lvl
      JLAST[$bdf]=$now
      [ "$escalated" = 2 ] && log "thermal renotify $bdf still $lvl at ${j}C"
    fi
  done < <(junction_samples)
}

# ---------- main ------------------------------------------------------------
FORCE_CAPTURE=0
trap 'FORCE_CAPTURE=1' USR1
trap 'stop_sampler; exit 0' TERM INT

start_sampler
ipmi_loop &
metrics_loop &
psu_loop &
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

  # Junction thermal watch - deliberately LAST and skipped on any tick where a
  # dropout fired, so one physical event cannot page twice. It never calls
  # capture_incident() and never touches ARMED: dropout detection must stay
  # live while a card is hot, which is exactly when it matters most.
  if [ -z "$reason" ] && [ "$JUNCTION_CRIT" -gt 0 ]; then
    junction_check
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
