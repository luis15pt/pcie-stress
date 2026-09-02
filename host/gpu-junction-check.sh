#!/bin/bash
# Per-GPU junction (hotspot) temperature report.
#
# Vendor guidance: junction is the best early indicator of a thermally-failing
# RTX 5090, and a card sustained above 100C junction is due for service. No
# NVIDIA tool reports it.
#
# Reads the merged exposition the vram-metrics service already produces, so it
# sees exactly the values Prometheus sees and inherits the whole validity gate
# (staleness, core cross-check, impossible values, frozen registers). It does
# NOT spawn its own reader: a fourth concurrent BAR reader would be both
# wasteful and a second source of truth.
#
# Usage:
#   gpu-junction-check.sh                 one-shot table
#   gpu-junction-check.sh --watch [SECS]  refresh until interrupted
#   gpu-junction-check.sh --json          machine-readable
#   gpu-junction-check.sh --max           print the hottest valid junction only
#
# Exit status: 2 if any live GPU is at/above CRIT, 1 if any is at/above WARN,
# 0 otherwise (so it can gate a screening run).
set -u

METRICS_FILE=${METRICS_FILE:-/metrics.txt}
DATA_DIR=${DATA_DIR:-/var/log/gpu-recorder}
WARN=${JUNCTION_WARN:-95}
CRIT=${JUNCTION_CRIT:-100}

MODE=table; WATCH_SECS=2
case "${1:-}" in
  --watch) MODE=watch; WATCH_SECS=${2:-2} ;;
  --json)  MODE=json ;;
  --max)   MODE=max ;;
  --help|-h) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1 (try --help)" >&2; exit 64 ;;
esac

# GPUs with a latched XID are dead: their sensors report the value at the
# instant of death, frozen, and often high. Reporting that as a live
# temperature is how a dead card ends up looking like a thermal fault.
dead_bdfs() {
  local ids id
  ids=$(tail -n 400 "$DATA_DIR/telemetry.csv" 2>/dev/null | awk '
    $2=="GPU" && $NF ~ /^[0-9]+$/ && $NF+0 > 0 { bad[$3]=1 }
    END { for (g in bad) print g }')
  for id in $ids; do
    awk -F, -v i="$id" '$1==i {print $2}' "$DATA_DIR/gpu-map.txt" 2>/dev/null
  done
}

collect() { # bdf uuid junction core_tool core_nvml gddrmax margin valid reason
  local dead
  dead=$(dead_bdfs | paste -sd' ' -)
  awk -v deadlist=" $dead " '
    function lbl(s, key,   m) {
      if (match(s, key "=\"[^\"]*\"")) {
        m = substr(s, RSTART, RLENGTH); sub(/^[^"]*"/, "", m); sub(/"$/, "", m)
        return m
      }
      return ""
    }
    /^gpu_junction_temp_celsius\{/    { b=lbl($0,"pci_bus_id"); j[b]=$NF; seen[b]=1; u[b]=lbl($0,"gpu_uuid") }
    /^gpu_junction_temp_valid\{/      { b=lbl($0,"pci_bus_id"); v[b]=$NF; seen[b]=1; u[b]=lbl($0,"gpu_uuid") }
    /^gpu_core_temp_celsius\{.*source="gputemps"\}/ { ct[lbl($0,"pci_bus_id")]=$NF }
    /^gpu_core_temp_celsius\{.*source="nvml"\}/     { cn[lbl($0,"pci_bus_id")]=$NF }
    /^gddr6_vram_temp_max_celsius\{/  { vx[lbl($0,"pci_bus_id")]=$NF }
    /^gpu_thermal_margin_celsius\{/   { mg[lbl($0,"pci_bus_id")]=$NF }
    /^gpu_junction_invalid_reason\{/  { r[lbl($0,"pci_bus_id")]=lbl($0,"reason") }
    END {
      for (b in seen) {
        d = (index(deadlist, " " b " ") > 0) ? 1 : 0
        printf "%s %s %s %s %s %s %s %s %s %s\n", b,
          (u[b] != "" ? u[b] : "-"),
          (b in j  ? j[b]  : "NaN"), (b in ct ? ct[b] : "NaN"),
          (b in cn ? cn[b] : "NaN"), (b in vx ? vx[b] : "NaN"),
          (b in mg ? mg[b] : "NaN"), (b in v  ? v[b]  : 0),
          (b in r  ? r[b]  : "-"), d
      }
    }' "$METRICS_FILE" 2>/dev/null | sort
}

check_source() {
  if [ ! -f "$METRICS_FILE" ]; then
    echo "no $METRICS_FILE - is vram-metrics.service running?" >&2
    exit 3
  fi
  local age
  age=$(( $(date +%s) - $(stat -c%Y "$METRICS_FILE" 2>/dev/null || echo 0) ))
  if [ "$age" -gt 60 ]; then
    echo "WARNING: $METRICS_FILE is ${age}s stale - values below may be old" >&2
    echo "  check: systemctl status vram-metrics" >&2
  fi
}

verdict_of() { # <junction> <valid> <dead>
  [ "$3" = 1 ] && { echo "DEAD"; return; }
  [ "$2" = 1 ] || { echo "NO-DATA"; return; }
  case "$1" in ''|*[!0-9]*) echo "NO-DATA"; return ;; esac
  if   [ "$1" -ge "$CRIT" ]; then echo "SERVICE"
  elif [ "$1" -ge "$WARN" ]; then echo "WARN"
  else echo "OK"; fi
}

render_table() {
  local rc=0 any=0
  printf "%-14s %-10s %7s %7s %6s %6s %7s %7s  %s\n" \
    PCI GPU JUNCTION CORE DELTA GDDR MARGIN VALID VERDICT
  while read -r bdf uuid j ct cn vx mg valid reason dead; do
    [ -n "${bdf:-}" ] || continue
    any=1
    local delta=- vd
    if [ "$valid" = 1 ] && [ "$j" != NaN ] && [ "$ct" != NaN ]; then
      delta=$(( j - ct ))
    fi
    vd=$(verdict_of "$j" "$valid" "$dead")
    [ "$vd" = SERVICE ] && rc=2
    [ "$vd" = WARN ] && [ "$rc" -lt 1 ] && rc=1
    printf "%-14s %-10s %7s %7s %6s %6s %7s %7s  %s%s\n" \
      "$bdf" "${uuid:4:9}" "$j" "$ct" "$delta" "$vx" "$mg" "$valid" \
      "$vd" "$([ "$reason" != - ] && printf " (%s)" "$reason")"
  done < <(collect)
  [ "$any" = 1 ] || { echo "no GPUs found in $METRICS_FILE" >&2; return 3; }
  echo ""
  echo "MARGIN is NVIDIA's official T.Limit: LOWER IS HOTTER (it is 90 - core)."
  echo "Thresholds: WARN >= ${WARN}C, SERVICE >= ${CRIT}C junction."
  echo "A reading only supports a service claim if taken under a defined load;"
  echo "use gpu-heat-screen.sh for the reference soak."
  return $rc
}

case "$MODE" in
  table) check_source; render_table ;;
  watch)
    check_source
    trap 'echo; exit 0' INT
    while true; do
      clear
      printf "%s  (refresh %ss, Ctrl-C to stop)\n\n" "$(date -Is)" "$WATCH_SECS"
      render_table || true
      sleep "$WATCH_SECS"
    done ;;
  max)
    check_source
    collect | awk '$8==1 && $10==0 && $3!="NaN" && $3+0>m {m=$3+0} END{print (m?m:"NaN")}' ;;
  json)
    check_source
    collect | awk 'BEGIN{printf "["; n=0}
      { if (n++) printf ","
        printf "{\"pci_bus_id\":\"%s\",\"gpu_uuid\":\"%s\",\"junction_c\":%s,", $1,$2,($3=="NaN"?"null":$3)
        printf "\"core_gputemps_c\":%s,\"core_nvml_c\":%s,", ($4=="NaN"?"null":$4),($5=="NaN"?"null":$5)
        printf "\"gddr_max_c\":%s,\"thermal_margin_c\":%s,", ($6=="NaN"?"null":$6),($7=="NaN"?"null":$7)
        printf "\"valid\":%s,\"invalid_reason\":%s,\"dead\":%s}", $8,($9=="-"?"null":"\""$9"\""),($10?"true":"false") }
      END{print "]"}' ;;
esac
