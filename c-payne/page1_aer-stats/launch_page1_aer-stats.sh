#!/bin/busybox sh

while true; do
  clear
  echo 'PCIe Stress Test Tool by C-Payne (c-payne.com) '$1
  echo 'Alt+F1 AER Statistics | Alt+F2 Lane Margining | Alt+F3 PCIe Port Registers | Alt+F4 nvidia-smi'
  echo 'Alt+F5 prime95 | Alt+F6 oclStress | Alt+F7 gpu_burn | Alt+F8 nvmeStress | Alt+F9-F12 Consoles'
  cd /c-payne/page1_aer-stats/
  ./mainboard.sh
  echo -n 'Uptime: '
  awk '{print int($1/3600)":"int(($1%3600)/60)":"int($1%60)}' /proc/uptime
sleep 3
  clear
done
