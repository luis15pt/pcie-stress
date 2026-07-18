#!/bin/busybox sh

while true; do
  clear
  echo 'PCIe Stress Test Tool by C-Payne (c-payne.com) '$1
  echo ''
  echo 'Read PCIe Port Registers.'
  read -p "Press any key to continue... " -n1 -s
  cd /c-payne/page3_registers/
  ./mainboard.sh
done
