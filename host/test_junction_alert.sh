#!/bin/bash
# Offline test of the recorder's junction alerting state machine (plan V14).
#
# Loads the recorder's functions WITHOUT running its main loop, then drives
# junction_check() against a synthetic /metrics.txt. The dedupe is the part
# most likely to be wrong, and the "must not disarm dropout detection"
# property is the one that would be a serious regression if broken - both are
# asserted here, with no GPU required.
set -u
cd "$(dirname "$0")"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed '/^# ---------- main/,$d' gpu-dropout-recorder.sh > "$T/lib.sh"

export DATA_DIR="$T/data"; mkdir -p "$DATA_DIR"
export METRICS_FILE="$T/metrics.txt"
export RECORDER_CONF=/nonexistent
export WEBHOOK_URL="http://127.0.0.1:1/hook"   # never actually posted to
export JUNCTION_SUSTAIN=6 JUNCTION_CRIT=100 JUNCTION_WARN=95
export JUNCTION_CLEAR_TICKS=12 JUNCTION_CLEAR_HYST=3 JUNCTION_RENOTIFY=3600
# shellcheck disable=SC1090
. "$T/lib.sh" >/dev/null 2>&1

ARMED=1
FAILS=0
WEBHOOKS=""
DEAD_IDS=""

log() { :; }
dead_gpus_from_ring() { [ -z "$DEAD_IDS" ] || printf "%s\n" "$DEAD_IDS"; }
capture_thermal_snapshot() { printf "%s" "$DATA_DIR/thermal-fake"; }
send_thermal_webhook() { WEBHOOKS="$WEBHOOKS $1:$2:$3"; }
capture_incident() { FAILS=$((FAILS+1)); echo "  FAIL: junction path called capture_incident!"; }

set_j() { # set_j <bdf> <junction> <core>
  cat > "$METRICS_FILE" << METRICS
gpu_junction_temp_celsius{gpu_uuid="GPU-x",pci_bus_id="$1"} $2
gpu_junction_temp_valid{gpu_uuid="GPU-x",pci_bus_id="$1"} 1
gpu_core_temp_celsius{gpu_uuid="GPU-x",pci_bus_id="$1",source="gputemps"} $3
gpu_core_temp_celsius{gpu_uuid="GPU-x",pci_bus_id="$1",source="nvml"} $3
gddr6_vram_temp_max_celsius{gpu_uuid="GPU-x",pci_bus_id="$1"} 88
gddr6_vram_temp_mean_celsius{gpu_uuid="GPU-x",pci_bus_id="$1"} 85
METRICS
}
reset_state() {
  JSTATE=(); JSTREAK=(); JCLEAR=(); JLAST=(); JPEAK=(); JLVL=(); WEBHOOKS=""
}
ticks() { local n=$1; while [ "$n" -gt 0 ]; do junction_check; n=$((n-1)); done; }
count() { printf "%s" "$WEBHOOKS" | tr ' ' '\n' | grep -c . ; }
expect() { # expect <label> <want> <got>
  if [ "$2" = "$3" ]; then printf "  ok   %-46s %s\n" "$1" "$3"
  else printf "  FAIL %-46s got %s want %s\n" "$1" "$3" "$2"; FAILS=$((FAILS+1)); fi
}

BDF=0000:81:00.0
echo "== warn escalation needs the sustain window =="
set_j $BDF 97 80
ticks 5;  expect "5 ticks at 97C: silent" 0 "$(count)"
ticks 1;  expect "6th tick: exactly one warn" 1 "$(count)"
ticks 30; expect "30 more ticks at 97C: still one" 1 "$(count)"

echo "== crit escalates once, then only hourly =="
set_j $BDF 103 84
ticks 5;  expect "5 ticks at 103C: not yet" 1 "$(count)"
ticks 1;  expect "6th tick: crit fires" 2 "$(count)"
ticks 60; expect "60 more ticks at 103C: no repeat" 2 "$(count)"
JLAST[$BDF]=$(( $(date +%s) - JUNCTION_RENOTIFY - 1 ))
ticks 1;  expect "after RENOTIFY: one reminder" 3 "$(count)"
ticks 30; expect "then quiet again" 3 "$(count)"

echo "== recovery requires sustained hysteresis =="
set_j $BDF 96 78
ticks 20; expect "96C is still warn band: no new alert" 3 "$(count)"
expect "state stays crit while hot" crit "${JSTATE[$BDF]}"
set_j $BDF 90 70
ticks 11; expect "11 clear ticks: not yet recovered" crit "${JSTATE[$BDF]}"
ticks 1;  expect "12th clear tick: recovered" ok "${JSTATE[$BDF]}"
expect "recovery sent no webhook" 3 "$(count)"

echo "== a single-tick spike out of a warm spell must not page =="
reset_state
set_j $BDF 97 80
ticks 20; expect "warm at 97C: one warn" 1 "$(count)"
set_j $BDF 103 84
ticks 1;  expect "one tick at 103C: NOT paged" 1 "$(count)"
set_j $BDF 97 80
ticks 3;  expect "back to 97C: still not paged" 1 "$(count)"
set_j $BDF 103 84
ticks 6;  expect "sustained 103C: now paged" 2 "$(count)"

echo "== a new episode after recovery can alert again =="
reset_state
set_j $BDF 103 84
ticks 6;  expect "first crit episode" 1 "$(count)"
set_j $BDF 90 70
ticks 12; expect "recovered" ok "${JSTATE[$BDF]}"
set_j $BDF 105 86
ticks 6;  expect "second episode pages again" 2 "$(count)"

echo "== a dead card must never alert =="
reset_state
printf "3,%s,GPU-x\n" "$BDF" > "$DATA_DIR/gpu-map.txt"
DEAD_IDS="3:79"
set_j $BDF 120 95
ticks 20; expect "latched-XID GPU at 120C: silent" 0 "$(count)"

echo "== invalid readings must never alert =="
DEAD_IDS=""
cat > "$METRICS_FILE" << METRICS
gpu_junction_temp_valid{gpu_uuid="GPU-x",pci_bus_id="$BDF"} 0
gpu_junction_invalid_reason{gpu_uuid="GPU-x",pci_bus_id="$BDF",reason="impossible"} 1
gpu_core_temp_celsius{gpu_uuid="GPU-x",pci_bus_id="$BDF",source="gputemps"} 84
METRICS
ticks 20; expect "valid=0: silent" 0 "$(count)"

echo "== the critical invariant =="
expect "ARMED never modified" 1 "$ARMED"

echo ""
if [ "$FAILS" = 0 ]; then echo "all pass"; else echo "$FAILS FAILURE(S)"; exit 1; fi
