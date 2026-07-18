#!/bin/bash
# Restore the GPU Link Control registers saved by preflight.sh.
# Usage: sudo ./restore.sh pcie-state-<date>.txt
set -eu

STATEFILE=${1:?usage: restore.sh <pcie-state-file>}
SETPCI=$(command -v setpci || echo "$(dirname "$0")/bin/setpci")

while read -r bdf lnkctl lnkctl2; do
  case "$bdf" in \#*|'') continue ;; esac
  lc=${lnkctl#LNKCTL=}
  lc2=${lnkctl2#LNKCTL2=}
  # restore only the bits the tool touches: ASPM (1:0) + HAWD (9) in LNKCTL, HASD (5) in LNKCTL2
  "$SETPCI" -s "$bdf" CAP_EXP+10.w=0x$lc:0x0203
  "$SETPCI" -s "$bdf" CAP_EXP+30.w=0x$lc2:0x0020
  echo "$bdf: restored LNKCTL(ASPM,HAWD)<-0x$lc LNKCTL2(HASD)<-0x$lc2"
done < "$STATEFILE"
