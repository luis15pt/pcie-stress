#!/bin/bash
# Offline test for per-GPU dropout arming.
#
# Regression test for a flaw that made the recorder silently deaf: a global
# ARMED latch was cleared by the FIRST dead GPU and could only re-arm once the
# dead list was completely EMPTY. On a host carrying one permanently dead card
# that never happens, so no subsequent dropout on that host was ever captured.
# Both production hosts were in that state when it was found.
set -u
cd "$(dirname "$0")"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed '/^# ---------- main/,$d' gpu-dropout-recorder.sh > "$T/lib.sh"
export DATA_DIR="$T/data"; mkdir -p "$DATA_DIR"
export RECORDER_CONF=/nonexistent
# shellcheck disable=SC1090
. "$T/lib.sh" >/dev/null 2>&1

FAILS=0
DEAD_SET=""
dead_gpus_from_ring() { for d in $DEAD_SET; do printf "%s\n" "$d"; done; }

expect() {
  if [ "$2" = "$3" ]; then printf "  ok   %-44s %s\n" "$1" "[$3]"
  else printf "  FAIL %-44s got [%s] want [%s]\n" "$1" "$3" "$2"; FAILS=$((FAILS+1)); fi
}

echo "== a host that boots with a dead card =="
DEAD_SET="0:79"
KNOWN_DEAD=$(printf "%s\n" $DEAD_SET | cut -d: -f1 | sort -un | paste -sd" " -)
expect "startup set remembered" "0" "$KNOWN_DEAD"
detect_new_dead; expect "no new dead on first poll" "" "$NEW_DEAD"
detect_new_dead; expect "still nothing 2nd poll" "" "$NEW_DEAD"
detect_new_dead; expect "still nothing 3rd poll" "" "$NEW_DEAD"

echo "== THE BUG: a second card dies on that same host =="
DEAD_SET="0:79 3:79"
detect_new_dead; expect "detects the NEW card only" "3" "$NEW_DEAD"
detect_new_dead; expect "does not re-report it" "" "$NEW_DEAD"

echo "== a third dies later =="
DEAD_SET="0:79 3:79 4:31"
detect_new_dead; expect "detects it" "4" "$NEW_DEAD"
detect_new_dead; expect "quiet afterwards" "" "$NEW_DEAD"

echo "== recovery then a fresh death re-arms that GPU =="
DEAD_SET="0:79 4:31"
detect_new_dead; expect "gpu3 recovered: nothing new" "" "$NEW_DEAD"
DEAD_SET="0:79 3:79 4:31"
detect_new_dead; expect "gpu3 dies again: fires again" "3" "$NEW_DEAD"

echo "== two dying in the same tick =="
KNOWN_DEAD=""; DEAD_SET="1:79 2:79"
detect_new_dead; expect "both reported" "1 2" "$NEW_DEAD"
detect_new_dead; expect "then quiet" "" "$NEW_DEAD"

echo "== a fully healthy host stays quiet =="
KNOWN_DEAD=""; DEAD_SET=""
detect_new_dead; expect "no GPUs dead" "" "$NEW_DEAD"
detect_new_dead; expect "still none" "" "$NEW_DEAD"

echo ""
if [ "$FAILS" = 0 ]; then echo "all pass"; else echo "$FAILS FAILURE(S)"; exit 1; fi
