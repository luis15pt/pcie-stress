#!/bin/busybox sh
MAINBOARD='generic'
export MAINBOARD
SLOT='generic'
export SLOT
echo ''
echo 'Generic Platform: AER statistics not available!'
echo 'Running the Bandwidth and Stress Test is still possible!'
echo ''
echo 'to check for PCIe AER:'
echo '1. Make sure the PCIe AER capability is enabled in BIOS'
echo '2. go to a free Console (for Example ALT+F12)'
echo '3. type "dmesg | grep AER" to look for AER messages in the kernel log'
echo ''
