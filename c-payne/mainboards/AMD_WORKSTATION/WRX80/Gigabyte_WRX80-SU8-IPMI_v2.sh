#!/bin/busybox sh

MAINBOARD='Gigabyte WRX80-SU8-IPMI Version 2'
echo $MAINBOARD
export MAINBOARD

SLOT='Slot 7 (closest to CPU)'
echo $SLOT
export SLOT
./port.sh 0000:80:01.1
./port.sh 0000:80:01.2
./port.sh 0000:80:01.3  
./port.sh 0000:80:01.4

SLOT='Slot 6'
echo $SLOT
export SLOT
./port.sh 0000:40:03.1
./port.sh 0000:40:03.2
./port.sh 0000:40:03.3  
./port.sh 0000:40:03.4

SLOT='Slot 5'
echo $SLOT
export SLOT
./port.sh 0000:00:01.1
./port.sh 0000:00:01.2
./port.sh 0000:00:01.3  
./port.sh 0000:00:01.4

SLOT='Slot 4'
echo $SLOT
export SLOT
./port.sh 0000:c0:01.1
./port.sh 0000:c0:01.2
./port.sh 0000:c0:01.3  
./port.sh 0000:c0:01.4

SLOT='Slot 3'
echo $SLOT
export SLOT
./port.sh 0000:40:01.1
./port.sh 0000:40:01.2
./port.sh 0000:40:01.3  
./port.sh 0000:40:01.4

SLOT='Slot 2 (x8)'
echo $SLOT
export SLOT
./port.sh 0000:00:03.3  
./port.sh 0000:00:03.4

SLOT='Slot 1'
echo $SLOT
export SLOT
./port.sh 0000:80:03.1
./port.sh 0000:80:03.2
./port.sh 0000:80:03.3  
./port.sh 0000:80:03.4

SLOT='M.2_A'
echo $SLOT
export SLOT
./port.sh 0000:00:03.1

SLOT='M.2_B'
echo $SLOT
export SLOT
./port.sh 0000:00:03.2
