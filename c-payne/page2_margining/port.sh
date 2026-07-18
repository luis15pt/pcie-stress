#!/bin/busybox sh

if test -f "/sys/bus/pci/devices/$1/current_link_speed"; then
  clear
  /bin/Lane-Margining -s $1 -t "Mainboard: $MAINBOARD Slot: $SLOT"
  read -p "Press any key to continue... " -n1 -s
fi  




