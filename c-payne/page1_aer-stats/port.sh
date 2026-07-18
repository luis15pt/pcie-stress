#!/bin/busybox sh

if test -f "/sys/bus/pci/devices/$1/current_link_speed"; then
  upstream_port=$1
  downstream_port=$(basename /sys/bus/pci/devices/$upstream_port/0000:*.0)
  downstream_port_F2=$(basename /sys/bus/pci/devices/$upstream_port/0000:*.1)
  
  current_link_speed=$(cat /sys/bus/pci/devices/$upstream_port/current_link_speed 2>/dev/null)
  max_link_speed=$(cat /sys/bus/pci/devices/$upstream_port/max_link_speed 2>/dev/null)
  current_link_width=$(cat /sys/bus/pci/devices/$upstream_port/current_link_width 2>/dev/null)
  max_link_width=$(cat /sys/bus/pci/devices/$upstream_port/max_link_width 2>/dev/null) 
  aer_dev_correctable_total=$(awk '{ if ( $1 == "TOTAL_ERR_COR" ) { sum += $2 } } END { print sum }' /sys/bus/pci/devices/$upstream_port/aer_dev_correctable /sys/bus/pci/devices/$upstream_port/*/aer_dev_correctable 2>/dev/null)
  aer_dev_nonfatal_total=$(awk '{ if ( $1 == "TOTAL_ERR_NONFATAL" ) { sum += $2 } } END { print sum }' /sys/bus/pci/devices/$upstream_port/aer_dev_nonfatal /sys/bus/pci/devices/$upstream_port/*/aer_dev_nonfatal 2>/dev/null)
  aer_dev_fatal_total=$(awk '{ if ( $1 == "TOTAL_ERR_FATAL" ) { sum += $2 } } END { print sum }' /sys/bus/pci/devices/$upstream_port/aer_dev_fatal /sys/bus/pci/devices/$upstream_port/*/aer_dev_fatal 2>/dev/null)

  aer_dev_correctable_upstream=$(awk '{ if ( $1 == "TOTAL_ERR_COR" ) { sum += $2 } } END { print sum }' /sys/bus/pci/devices/$upstream_port/aer_dev_correctable 2>/dev/null)
  aer_dev_nonfatal_upstream=$(awk '{ if ( $1 == "TOTAL_ERR_NONFATAL" ) { sum += $2 } } END { print sum }' /sys/bus/pci/devices/$upstream_port/aer_dev_nonfatal 2>/dev/null)
  aer_dev_fatal_upstream=$(awk '{ if ( $1 == "TOTAL_ERR_FATAL" ) { sum += $2 } } END { print sum }' /sys/bus/pci/devices/$upstream_port/aer_dev_fatal 2>/dev/null)

  aer_dev_correctable_downstream=$(awk '{ if ( $1 == "TOTAL_ERR_COR" ) { sum += $2 } } END { print sum }' /sys/bus/pci/devices/$downstream_port/aer_dev_correctable 2>/dev/null)
  aer_dev_nonfatal_downstream=$(awk '{ if ( $1 == "TOTAL_ERR_NONFATAL" ) { sum += $2 } } END { print sum }' /sys/bus/pci/devices/$downstream_port/aer_dev_nonfatal 2>/dev/null)
  aer_dev_fatal_downstream=$(awk '{ if ( $1 == "TOTAL_ERR_FATAL" ) { sum += $2 } } END { print sum }' /sys/bus/pci/devices/$downstream_port/aer_dev_fatal 2>/dev/null)

  aer_dev_correctable_downstream_F2=$(awk '{ if ( $1 == "TOTAL_ERR_COR" ) { sum += $2 } } END { print sum }' /sys/bus/pci/devices/$downstream_port_F2/aer_dev_correctable 2>/dev/null)
  aer_dev_nonfatal_downstream_F2=$(awk '{ if ( $1 == "TOTAL_ERR_NONFATAL" ) { sum += $2 } } END { print sum }' /sys/bus/pci/devices/$downstream_port_F2/aer_dev_nonfatal 2>/dev/null)
  aer_dev_fatal_downstream_F2=$(awk '{ if ( $1 == "TOTAL_ERR_FATAL" ) { sum += $2 } } END { print sum }' /sys/bus/pci/devices/$downstream_port_F2/aer_dev_fatal 2>/dev/null)

  echo -e -n '  '${1#"0000:"}'->'${downstream_port#"0000:"}','

  if  [ "$current_link_speed" != "$max_link_speed" ]; then
    echo -e -n '\033[0;31m'
  fi
  echo -e -n ' '$current_link_speed',\033[0m'

  if  [ "$current_link_width" != "$max_link_width" ]; then
    echo -e -n '\033[0;31m'
  fi
  echo -e -n ' x'$current_link_width',\033[0m'

    if  [ "$aer_dev_correctable_total" != 0 ]; then
    echo -e -n '\033[0;31m'
  fi
  echo -e -n ' AER:'$aer_dev_correctable_total'\033[0m'

  if  [ "$aer_dev_correctable_upstream" != 0 ]; then
    echo -e -n '\033[0;31m'
  fi
  echo -e -n ' (root:'$aer_dev_correctable_upstream',\033[0m'

  if  [ "$aer_dev_correctable_downstream" != 0 ]; then
    echo -e -n '\033[0;31m'
  fi
  echo -e -n ' device:'$aer_dev_correctable_downstream'),\033[0m'

  if  [ "$aer_dev_nonfatal_total" != 0 ]; then
    echo -e -n '\033[0;31m'
  fi
  echo -e -n ' nonfatal: '$aer_dev_nonfatal_total'\033[0m'
  
  if  [ "$aer_dev_fatal_total" != 0 ]; then
    echo -e -n '\033[0;31m'
  fi
  echo -e -n ', fatal: '$aer_dev_fatal_total'\033[0m'

  echo -e -n '\n'
fi  


