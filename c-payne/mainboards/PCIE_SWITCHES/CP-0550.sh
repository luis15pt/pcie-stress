#!/bin/busybox sh

MAINBOARD='PCIe gen5 MCIO Switch 52-Lane'
echo $MAINBOARD
export MAINBOARD

upstream_ports=$(lspci -vv -D -d 1f18:0102:0604 2>/dev/null | awk '/^[0-9a-fA-F]+:[0-9a-fA-F]+:[0-9a-fA-F]+\.[0-9a-fA-F]+/ {dev=$1} /Express.*Upstream Port/ {print dev}')
n=0

for port_up in $upstream_ports; do
  domain="${port_up%%:*}"
  port_up="${port_up#*:}"

  SLOT='Switch '$n': '$(lspci -s 2>/dev/null "$domain:$port_up" | awk '{ $1=""; sub(/^ /,""); print }')
  n=$((n+1))
  echo $SLOT
  export SLOT


  echo -n up:
  ./port.sh $domain:$(lspci -PP -s $domain:$port_up 2>/dev/null | awk '{print $1}' | awk -F'/' '{print $(NF-1)}')

  downstream_ports=$(lspci -PP -s $domain:*:*.* 2>/dev/null | awk '{print $1}' | awk -F'/' -v port="$port_up" '{ if ($(NF-1) == port) print $(NF) }')
  for port_down in $downstream_ports; do
    echo -n down:
    ./port.sh $domain:$port_down
  done
  echo ''
done
