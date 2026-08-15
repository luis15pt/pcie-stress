#!/bin/bash
# GPU-temperature-driven chassis fan control (BMC/IPMI).
#
# Curve: duty = MIN_DUTY below T_LOW, linear MIN->MAX between T_LOW..T_HIGH,
# MAX_DUTY at/above T_HIGH (i.e. "spin up before the software throttle").
# Emergency: at/above T_EMERG force EMERG_DUTY regardless of MAX_DUTY.
# Failsafe: if GPU temps are unreadable, go to MAX_DUTY (fail cool, not quiet).
# Smoothing: increases apply immediately; decreases step down slowly to avoid
# fan hunting.
#
# The IPMI command that sets duty differs per board/BMC firmware — configure
# FAN_SET_CMD in /etc/gpu-fan-control.conf ({DUTY} is replaced 0-100).
# `gpu-fan-control.sh probe` helps discover the right one (see conf).
set -u

CONF=${FANCTL_CONF:-/etc/gpu-fan-control.conf}
[ -f "$CONF" ] && . "$CONF"

MIN_DUTY=${MIN_DUTY:-20}      # your chosen quiet floor
MAX_DUTY=${MAX_DUTY:-50}      # ceiling of the normal curve
T_LOW=${T_LOW:-70}            # curve starts rising here
T_HIGH=${T_HIGH:-85}          # curve reaches MAX_DUTY here ("before sw throttle")
T_EMERG=${T_EMERG:-92}        # safety override threshold
EMERG_DUTY=${EMERG_DUTY:-100} # safety override duty
INTERVAL=${INTERVAL:-5}
STEP_DOWN=${STEP_DOWN:-3}     # max % decrease per tick (increases are instant)
FAN1_DUTY=${FAN1_DUTY:-20}    # CPU fan (FAN1) held fixed at this duty
FAN_SET_CMD=${FAN_SET_CMD:-}  # e.g. "ipmitool raw 0x3a 0x01 {FAN1} {DUTY} {DUTY} {DUTY} {DUTY} {DUTY} {DUTY} {DUTY}"

log() { echo "$(date -Is) $*"; }

max_gpu_temp() { # hottest GPU via DCGM (hang-safe); empty on failure
  timeout 15 dcgmi dmon -e 150 -c 1 2>/dev/null | awk '$1=="GPU" && $3 ~ /^[0-9]+$/ {if ($3+0>m) m=$3+0} END {if (m) print m}'
}

set_duty() { # set_duty <0-100>
  [ -n "$FAN_SET_CMD" ] || { log "FAN_SET_CMD not configured - see /etc/gpu-fan-control.conf"; return 1; }
  local cmd=${FAN_SET_CMD//\{DUTY\}/$1}
  cmd=${cmd//\{FAN1\}/$FAN1_DUTY}
  timeout 20 $cmd >/dev/null 2>&1
}

curve() { # curve <temp> -> duty
  local t=$1
  if [ "$t" -ge "$T_EMERG" ]; then echo "$EMERG_DUTY"; return; fi
  if [ "$t" -ge "$T_HIGH" ]; then echo "$MAX_DUTY"; return; fi
  if [ "$t" -le "$T_LOW" ];  then echo "$MIN_DUTY"; return; fi
  echo $(( MIN_DUTY + (t - T_LOW) * (MAX_DUTY - MIN_DUTY) / (T_HIGH - T_LOW) ))
}

probe() { # try known ASRock Rack raw formats, verify by RPM delta
  command -v ipmitool >/dev/null || { echo "ipmitool required"; exit 1; }
  local base after fmt
  base=$(timeout 25 ipmitool sdr elist 2>/dev/null | awk -F'|' '/^FAN[2-7] /{gsub(/[^0-9]/,"",$5); s+=$5; n++} END{if(n) print int(s/n)}')
  echo "baseline avg fan RPM: ${base:-unknown}"
  local candidates=(
    "ipmitool raw 0x3a 0x01 {FAN1} {DUTY} {DUTY} {DUTY} {DUTY} {DUTY} {DUTY} {DUTY}"
    "ipmitool raw 0x3a 0xd6 {FAN1} {DUTY} {DUTY} {DUTY} {DUTY} {DUTY} {DUTY} {DUTY} {DUTY} {DUTY} {DUTY} {DUTY} {DUTY} {DUTY} {DUTY} {DUTY}"
  )
  for fmt in "${candidates[@]}"; do
    echo "trying: $fmt (at 40%)"
    local cmd=${fmt//\{DUTY\}/40}; cmd=${cmd//\{FAN1\}/$FAN1_DUTY}
    if timeout 20 $cmd >/dev/null 2>&1; then
      sleep 8
      after=$(timeout 25 ipmitool sdr elist 2>/dev/null | awk -F'|' '/^FAN[2-7] /{gsub(/[^0-9]/,"",$5); s+=$5; n++} END{if(n) print int(s/n)}')
      echo "  accepted by BMC; avg RPM now: ${after:-unknown} (baseline ${base:-?})"
      if [ -n "$after" ] && [ -n "$base" ] && [ "$after" -gt $((base + 200)) ]; then
        echo "  >>> RPM rose - THIS is your FAN_SET_CMD. Restoring ${MIN_DUTY}%."
        cmd=${fmt//\{DUTY\}/$MIN_DUTY}; cmd=${cmd//\{FAN1\}/$FAN1_DUTY}; timeout 20 $cmd >/dev/null 2>&1
        echo "FAN_SET_CMD=\"$fmt\""
        exit 0
      fi
      cmd=${fmt//\{DUTY\}/$MIN_DUTY}; cmd=${cmd//\{FAN1\}/$FAN1_DUTY}; timeout 20 $cmd >/dev/null 2>&1
    else
      echo "  rejected by BMC"
    fi
  done
  echo "no candidate verified - set FAN_SET_CMD manually (check board docs / BMC UI network trace)"
  exit 1
}

case "${1:-run}" in
  probe) probe ;;
  run) ;;
  *) echo "usage: $0 [run|probe]"; exit 1 ;;
esac

trap 'log "exiting - setting fans to ${MAX_DUTY}% as failsafe"; set_duty "$MAX_DUTY"; exit 0' TERM INT

CUR=-1
FAILS=0
log "fan control: ${MIN_DUTY}%..${MAX_DUTY}% over ${T_LOW}..${T_HIGH}C, emergency ${EMERG_DUTY}% at ${T_EMERG}C, interval ${INTERVAL}s"
while true; do
  T=$(max_gpu_temp)
  if [ -z "$T" ]; then
    FAILS=$((FAILS + 1))
    if [ "$FAILS" -ge 3 ] && [ "$CUR" != "$MAX_DUTY" ]; then
      log "GPU temps unreadable x$FAILS - failsafe ${MAX_DUTY}%"
      set_duty "$MAX_DUTY" && CUR=$MAX_DUTY
    fi
    sleep "$INTERVAL"; continue
  fi
  FAILS=0
  WANT=$(curve "$T")
  if [ "$WANT" -gt "$CUR" ]; then
    TARGET=$WANT                                   # increases: immediate
  elif [ "$WANT" -lt "$CUR" ]; then
    TARGET=$((CUR - STEP_DOWN))                    # decreases: gentle ramp
    [ "$TARGET" -lt "$WANT" ] && TARGET=$WANT
  else
    TARGET=$CUR
  fi
  if [ "$TARGET" != "$CUR" ]; then
    if set_duty "$TARGET"; then
      log "hottest GPU ${T}C -> fans ${TARGET}%"
      CUR=$TARGET
    else
      log "fan set FAILED (duty ${TARGET}%)"
    fi
  fi
  sleep "$INTERVAL"
done
