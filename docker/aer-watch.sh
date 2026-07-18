#!/bin/bash
# Live PCIe health readout, modeled on the C-Payne page1 AER display but
# board-generic: finds every NVIDIA GPU, walks up to its root port via sysfs,
# and shows link speed/width vs max plus AER counters for both ends.
# Anything red = degraded link or nonzero error counter.
interval=${1:-3}

red=$'\033[0;31m'; grn=$'\033[0;32m'; rst=$'\033[0m'

val() { cat "$1" 2>/dev/null || echo '?'; }
cor() { awk '$1=="TOTAL_ERR_COR"{print $2}' "$1/aer_dev_correctable" 2>/dev/null || echo '?'; }
fat() { awk '$1=="TOTAL_ERR_FATAL"{print $2}' "$1/aer_dev_fatal" 2>/dev/null || echo '?'; }
nf()  { awk '$1=="TOTAL_ERR_NONFATAL"{print $2}' "$1/aer_dev_nonfatal" 2>/dev/null || echo '?'; }
paint() { # paint <value> <zero-is-good: yes|no>; prints value colored
  if [ "$1" = "?" ]; then printf '?'
  elif [ "$1" != "0" ] && [ "$2" = yes ]; then printf '%s%s%s' "$red" "$1" "$rst"
  else printf '%s' "$1"; fi
}

while true; do
  printf '\033[H\033[2J'
  echo "C-Payne-style PCIe/AER monitor (containerized) - $(date '+%H:%M:%S')  uptime: $(awk '{print int($1/3600)":"int(($1%3600)/60)":"int($1%60)}' /proc/uptime)"
  echo ''
  printf '%-14s %-14s %-22s %-10s %-28s %s\n' 'GPU (endpoint)' 'root port' 'link (cur / max)' 'width' 'AER cor (port/dev)' 'nonfatal/fatal'

  for dev in /sys/bus/pci/devices/*; do
    bdf=$(basename "$dev")
    case "$bdf" in *.0) ;; *) continue ;; esac
    [ "$(val "$dev/vendor")" = "0x10de" ] || continue
    case "$(val "$dev/class")" in 0x03*) ;; *) continue ;; esac

    port=$(basename "$(dirname "$(realpath "$dev")")")
    pdev="/sys/bus/pci/devices/$port"

    cs=$(val "$dev/current_link_speed"); ms=$(val "$dev/max_link_speed")
    cw=$(val "$dev/current_link_width"); mw=$(val "$dev/max_link_width")
    speed="${cs%% *} / ${ms%% *} GT/s"
    width="x$cw/x$mw"
    # note: max = endpoint capability; x8/Gen4 topologies (bifurcated, SLIM cables)
    # legitimately run below endpoint max — compare against the ROOT PORT's cap.
    pcs=$(val "$pdev/current_link_speed"); pms=$(val "$pdev/max_link_speed")
    scol=""; [ "$pcs" != "$pms" ] && scol=$red
    p_c=$(cor "$pdev"); d_c=$(cor "$dev")
    p_n=$(nf "$pdev");  d_n=$(nf "$dev")
    p_f=$(fat "$pdev"); d_f=$(fat "$dev")

    printf '%-14s %-14s %s%-22s%s %-10s cor: %s / %-16s nf: %s/%s fat: %s/%s\n' \
      "$bdf" "$port" "$scol" "$speed" "$rst" "$width" \
      "$(paint "$p_c" yes)" "$(paint "$d_c" yes)" \
      "$(paint "$p_n" yes)" "$(paint "$d_n" yes)" \
      "$(paint "$p_f" yes)" "$(paint "$d_f" yes)"
  done

  echo ''
  echo 'Non-GPU devices with nonzero AER correctable counters:'
  found=0
  for f in /sys/bus/pci/devices/*/aer_dev_correctable; do
    d=$(dirname "$f"); bdf=$(basename "$d")
    [ "$(val "$d/vendor")" = "0x10de" ] && continue
    c=$(cor "$d")
    if [ "$c" != "?" ] && [ "$c" != "0" ]; then
      printf '  %s%-14s cor: %s%s  (%s)\n' "$red" "$bdf" "$c" "$rst" "$(lspci -s "$bdf" 2>/dev/null | cut -d' ' -f2- | cut -c1-60)"
      found=1
    fi
  done
  [ $found -eq 0 ] && echo '  (none)'

  echo ''
  echo 'Recent kernel AER/Xid events:'
  dmesg 2>/dev/null | grep -iE 'AER:|Xid' | tail -6 || echo '  (dmesg unavailable - run container with --privileged)'
  sleep "$interval"
done
