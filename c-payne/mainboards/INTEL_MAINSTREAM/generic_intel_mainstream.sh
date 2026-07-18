#!/bin/busybox sh

MAINBOARD='generic Intel Mainstream'
echo $MAINBOARD
export MAINBOARD

SLOT='CPU Lanes'
echo $SLOT
export SLOT
./port.sh 0000:00:01.0
./port.sh 0000:00:01.1
./port.sh 0000:00:01.2
