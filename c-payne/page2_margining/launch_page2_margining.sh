#!/bin/busybox sh

while true; do
  clear
  echo 'PCIe Stress Test Tool by C-Payne (c-payne.com) '$1
  echo ''
  echo 'PCIe Lane Margining.'
  read -p "Press any key to continue... " -n1 -s
  cd /c-payne/page2_margining/
  ./mainboard.sh
done
