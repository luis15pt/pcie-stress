#!/bin/bash
# Preflight check before running the C-Payne stress tests on a live system.
# Reads and decodes the exact registers the tool's setpci commands modify,
# and saves their current values so restore.sh can put them back.
#
# The original bootable USB runs:
#   setpci -d 10de: -s '*:*.0' CAP_EXP+30.w=0x0020:0x0020   # LNKCTL2: set HASD (disable autonomous speed)
#   setpci -d 10de: -s '*:*.0' CAP_EXP+10.w=0x0200:0x0203   # LNKCTL:  set HAWD, clear ASPM (disable autonomous width + ASPM)
#
# Usage: sudo ./preflight.sh          # inspect + save state to pcie-state-<date>.txt
set -u

SETPCI=$(command -v setpci || echo "$(dirname "$0")/bin/setpci")
LSPCI=$(command -v lspci || echo "$(dirname "$0")/bin/lspci")
STATEFILE="$(dirname "$0")/pcie-state-$(date +%Y%m%d-%H%M%S).txt"

echo '=== Kernel boot parameters ==='
echo "cmdline: $(cat /proc/cmdline)"
for opt in pci=nobar pci=realloc=off pci=norom; do
  if grep -qw "$opt" /proc/cmdline; then
    echo "  $opt: present (same as USB tool)"
  else
    echo "  $opt: NOT present (USB tool boots with it; only affects boot-time BAR/ROM setup, not required)"
  fi
done

echo ''
echo '=== AER support ==='
if compgen -G '/sys/bus/pci/devices/*/aer_dev_correctable' > /dev/null; then
  echo '  AER sysfs counters available.'
else
  echo '  WARNING: no aer_dev_* files found - enable PCIe AER in BIOS (and check "pcie_aports"/AER kernel support).'
fi

echo ''
echo '=== NVIDIA GPU link registers (what the tool would modify) ==='
GPUS=$("$LSPCI" -d 10de: -D 2>/dev/null | awk '$2=="VGA"||$2=="3D"||/controller/{print $1}' | sort -u)
if [ -z "$GPUS" ]; then
  echo '  No NVIDIA (10de:) devices found.'
  exit 1
fi

echo "# saved by preflight.sh on $(date)" > "$STATEFILE"
echo "# format: <bdf> LNKCTL=<hex> LNKCTL2=<hex>" >> "$STATEFILE"

for bdf in $GPUS; do
  # only function .0, matching the tool's -s '*:*.0'
  case "$bdf" in *.0) ;; *) continue ;; esac
  lnkctl=$("$SETPCI" -s "$bdf" CAP_EXP+10.w 2>/dev/null)
  lnkctl2=$("$SETPCI" -s "$bdf" CAP_EXP+30.w 2>/dev/null)
  if [ -z "$lnkctl" ] || [ -z "$lnkctl2" ]; then
    echo "  $bdf: could not read config space (need root?)"
    continue
  fi
  echo "$bdf LNKCTL=$lnkctl LNKCTL2=$lnkctl2" >> "$STATEFILE"

  aspm=$(( 0x$lnkctl & 0x3 ))
  hawd=$(( (0x$lnkctl >> 9) & 1 ))
  hasd=$(( (0x$lnkctl2 >> 5) & 1 ))
  case $aspm in
    0) aspm_s='disabled' ;;
    1) aspm_s='L0s' ;;
    2) aspm_s='L1' ;;
    3) aspm_s='L0s+L1' ;;
  esac

  name=$("$LSPCI" -s "$bdf" 2>/dev/null | cut -d: -f3- | sed 's/^ //')
  spd=$(cat "/sys/bus/pci/devices/$bdf/current_link_speed" 2>/dev/null || echo '?')
  maxspd=$(cat "/sys/bus/pci/devices/$bdf/max_link_speed" 2>/dev/null || echo '?')
  wid=$(cat "/sys/bus/pci/devices/$bdf/current_link_width" 2>/dev/null || echo '?')
  maxwid=$(cat "/sys/bus/pci/devices/$bdf/max_link_width" 2>/dev/null || echo '?')

  echo "  $bdf  $name"
  echo "      link: $spd x$wid (max: $maxspd x$maxwid)"
  echo "      LNKCTL=0x$lnkctl  ASPM=$aspm_s  HAWD(autonomous-width-disable)=$hawd"
  echo "      LNKCTL2=0x$lnkctl2 HASD(autonomous-speed-disable)=$hasd"
  if [ "$aspm" -eq 0 ] && [ "$hawd" -eq 1 ] && [ "$hasd" -eq 1 ]; then
    echo '      -> already in the state the tool sets; setpci step would be a no-op'
  else
    echo '      -> tool would change this to: ASPM=disabled HAWD=1 HASD=1'
  fi
done

echo ''
echo "Current values saved to: $STATEFILE"
echo "After testing, run: sudo ./restore.sh $STATEFILE"
