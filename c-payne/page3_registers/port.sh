#!/bin/busybox sh

print_bits () {
  retval=$(echo $1 | rev)
  retval=${retval//0/ 0 | 0 | 0 | 0 |}
  retval=${retval//1/ 1 | 0 | 0 | 0 |}
  retval=${retval//2/ 0 | 1 | 0 | 0 |}
  retval=${retval//3/ 1 | 1 | 0 | 0 |}
  retval=${retval//4/ 0 | 0 | 1 | 0 |}
  retval=${retval//5/ 1 | 0 | 1 | 0 |}
  retval=${retval//6/ 0 | 1 | 1 | 0 |}
  retval=${retval//7/ 1 | 1 | 1 | 0 |}
  retval=${retval//8/ 0 | 0 | 0 | 1 |}
  retval=${retval//9/ 1 | 0 | 0 | 1 |}
  retval=${retval//a/ 0 | 1 | 0 | 1 |}
  retval=${retval//b/ 1 | 1 | 0 | 1 |}
  retval=${retval//c/ 0 | 0 | 1 | 1 |}
  retval=${retval//d/ 1 | 0 | 1 | 1 |}
  retval=${retval//e/ 0 | 1 | 1 | 1 |}
  retval=${retval//f/ 1 | 1 | 1 | 1 |}
  echo -e ${retval//1/'\033[0;31m'1'\033[0m'}
}

if test -f "/sys/bus/pci/devices/$1/current_link_speed"; then
  clear
  echo 'Mainboard: '$MAINBOARD
  echo 'Slot: '$SLOT
  echo ''

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

  echo -e -n 'Port: '$1','
  if  [ "$current_link_speed" != "$max_link_speed" ]; then
    echo -e -n '\033[0;31m'
  fi
  echo -e -n ' Speed: '$current_link_speed',\033[0m'
  if  [ "$current_link_width" != "$max_link_width" ]; then
    echo -e -n '\033[0;31m'
  fi
  echo -e -n ' Width: x'$current_link_width',\033[0m'
  if  [ "$aer_dev_correctable_total" != 0 ]; then
    echo -e -n '\033[0;31m'
  fi
  echo -e -n ' AER-corrected: '$aer_dev_correctable_total',\033[0m'
  if  [ "$aer_dev_nonfatal_total" != 0 ]; then
    echo -e -n '\033[0;31m'
  fi
  echo -e -n ' AER-nonfatal: '$aer_dev_nonfatal_total',\033[0m'
  if  [ "$aer_dev_fatal_total" != 0 ]; then
    echo -e -n '\033[0;31m'
  fi
  echo -e ' AER-fatal: '$aer_dev_fatal_total'\033[0m\n'


  echo -e 'Upstream Port: '$1
    lspci -s $upstream_port -vmm | grep --color=never ^Device:
   if  [ "$aer_dev_correctable_upstream" != 0 ]; then
    echo -e -n '\033[0;31m'
  fi
  echo -e -n 'AER-corrected: '$aer_dev_correctable_upstream',\033[0m'
  if  [ "$aer_dev_nonfatal_upstream" != 0 ]; then
    echo -e -n '\033[0;31m'
  fi
  echo -e -n ' AER-nonfatal: '$aer_dev_nonfatal_upstream',\033[0m'
  if  [ "$aer_dev_fatal_upstream" != 0 ]; then
    echo -e -n '\033[0;31m'
  fi
  echo -e ' AER-fatal: '$aer_dev_fatal_upstream'\033[0m'
  
  echo -e 'lane No. |0  | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |10 |11 |12 |13 |14 |15 |'
  echo -e -n 'gen3 ERR | '
  print_bits $(setpci -s $upstream_port ECAP0x19+0x08.w 2>/dev/null)
  
    echo -e -n 'DWST PRS |'
  for i in 0C 0E 10 12 14 16 18 1A 1C 1E 20 22 24 26 28 2A
    do
    echo -e -n $(setpci -s $upstream_port ECAP0x19+0x$i.b 2>/dev/null)' |'
  done
  
  echo -e -n '\nUPST PRS |'
  for i in 0D 0F 11 13 15 17 19 1B 1D 1F 21 23 25 27 29 2B
    do
    echo -e -n $(setpci -s $upstream_port ECAP0x19+0x$i.b 2>/dev/null)' |'
  done
  
  echo -e -n '\ngen4 ERR | '
  print_bits $(setpci -s $upstream_port ECAP0x26+0x10.w 2>/dev/null)
  echo -e -n 'gen4 RT1 | '
  print_bits $(setpci -s $upstream_port ECAP0x26+0x14.w 2>/dev/null)
  echo -e -n 'gen4 RT2 | '
  print_bits $(setpci -s $upstream_port ECAP0x26+0x18.w 2>/dev/null)

  echo -e -n 'gen4 PRS |'
  for i in 20 21 22 23 24 25 26 27 28 29 2A 2B 2C 2D 2E 2F
    do
    echo -e -n $(setpci -s $upstream_port ECAP0x26+0x$i.b 2>/dev/null)' |'
  done
  
  echo -e -n '\ngen5 PRS |'
  for i in 20 21 22 23 24 25 26 27 28 29 2A 2B 2C 2D 2E 2F
    do
    echo -e -n $(setpci -s $upstream_port ECAP0x2A+0x$i.b 2>/dev/null)' |'
  done
  echo -e '\n'
  
  echo -e 'Downstream Port: '${downstream_port#"0000:"}
  lspci -s $downstream_port -vmm | grep --color=never ^Device:
   if  [ "$aer_dev_correctable_downstream" != 0 ]; then
    echo -e -n '\033[0;31m'
  fi
  echo -e -n 'AER-corrected: '$aer_dev_correctable_downstream',\033[0m'
  if  [ "$aer_dev_nonfatal_downstream" != 0 ]; then
    echo -e -n '\033[0;31m'
  fi
  echo -e -n ' AER-nonfatal: '$aer_dev_nonfatal_downstream',\033[0m'
  if  [ "$aer_dev_fatal_downstream" != 0 ]; then
    echo -e -n '\033[0;31m'
  fi
  echo -e ' AER-fatal: '$aer_dev_fatal_downstream'\033[0m'
  
  echo -e 'lane No. |0  | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |10 |11 |12 |13 |14 |15 |'
  echo -e -n 'gen3 ERR | '
  print_bits $(setpci -s $downstream_port ECAP0x19+0x08.w 2>/dev/null)
  
  echo -e -n 'DWST PRS |'
  for i in 0C 0E 10 12 14 16 18 1A 1C 1E 20 22 24 26 28 2A
    do
    echo -e -n $(setpci -s $downstream_port ECAP0x19+0x$i.b 2>/dev/null)' |'
  done
  
  echo -e -n '\nUPST PRS |'
  for i in 0D 0F 11 13 15 17 19 1B 1D 1F 21 23 25 27 29 2B
    do
    echo -e -n $(setpci -s $downstream_port ECAP0x19+0x$i.b 2>/dev/null)' |'
  done
  
  echo -e -n '\ngen4 ERR | '
  print_bits $(setpci -s $downstream_port ECAP0x26+0x10.w 2>/dev/null)
  echo -e -n 'gen4 RT1 | '
  print_bits $(setpci -s $downstream_port ECAP0x26+0x14.w 2>/dev/null)
  echo -e -n 'gen4 RT2 | '
  print_bits $(setpci -s $downstream_port ECAP0x26+0x18.w 2>/dev/null)

  echo -e -n 'gen4 PRS |'
  for i in 20 21 22 23 24 25 26 27 28 29 2A 2B 2C 2D 2E 2F
    do
    echo -e -n $(setpci -s $downstream_port ECAP0x26+0x$i.b 2>/dev/null)' |'
  done
  
  echo -e -n '\ngen5 PRS |'
  for i in 20 21 22 23 24 25 26 27 28 29 2A 2B 2C 2D 2E 2F
    do
    echo -e -n $(setpci -s $downstream_port ECAP0x2A+0x$i.b 2>/dev/null)' |'
  done  
  echo -e '\n'
    
  if test -f "/sys/bus/pci/devices/$downstream_port_F2/current_link_speed"; then
    echo -e 'Downstream Port (Function 2): '
    lspci -s $downstream_port_F2  -vmm | grep --color=never ^Device:
    if  [ "$aer_dev_correctable_downstream_F2" != 0 ]; then
      echo -e -n '\033[0;31m'
    fi
      echo -e -n 'AER-corrected: '$aer_dev_correctable_downstream_F2',\033[0m'
    if  [ "$aer_dev_nonfatal_downstream_F2" != 0 ]; then
      echo -e -n '\033[0;31m'
    fi
      echo -e -n ' AER-nonfatal: '$aer_dev_nonfatal_downstream_F2',\033[0m'
    if  [ "$aer_dev_fatal_downstream_F2" != 0 ]; then
      echo -e -n '\033[0;31m'
    fi
    echo -e ' AER-fatal: '$aer_dev_fatal_downstream_F2'\033[0m'
    echo -e -n '\n'
  fi
  read -p "Press any key to continue... " -n1 -s
fi  




