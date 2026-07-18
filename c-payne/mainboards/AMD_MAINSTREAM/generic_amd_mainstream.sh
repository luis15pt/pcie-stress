#!/bin/busybox sh

MAINBOARD='generic AMD Mainstream'
echo $MAINBOARD
export MAINBOARD

SLOT='CPU Slot'
echo $SLOT
export SLOT
./port.sh 0000:00:01.1
./port.sh 0000:00:01.3
./port.sh 0000:00:01.4
./port.sh 0000:00:01.5
