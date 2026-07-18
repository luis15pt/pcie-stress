#!/bin/busybox sh

MAINBOARD='ASUS Pro WS WRX80E-SAGE SE WIFI'
echo $MAINBOARD
export MAINBOARD

SLOT='Slot 1 (closest to CPU)'
echo $SLOT
export SLOT
./port.sh 0000:40:01.1
./port.sh 0000:40:01.2
./port.sh 0000:40:01.3  
./port.sh 0000:40:01.4

SLOT='Slot 2'
echo $SLOT
export SLOT
./port.sh 0000:00:01.1
./port.sh 0000:00:01.2
./port.sh 0000:00:01.3  
./port.sh 0000:00:01.4

SLOT='Slot 3'
echo $SLOT
export SLOT
./port.sh 0000:20:03.1
./port.sh 0000:20:03.2
./port.sh 0000:20:03.3  
./port.sh 0000:20:03.4

SLOT='Slot 4'
echo $SLOT
export SLOT
./port.sh 0000:60:03.1
./port.sh 0000:60:03.2
./port.sh 0000:60:03.3  
./port.sh 0000:60:03.4

SLOT='Slot 5'
echo $SLOT
export SLOT
./port.sh 0000:60:01.1
./port.sh 0000:60:01.2
./port.sh 0000:60:01.3  
./port.sh 0000:60:01.4

SLOT='Slot 6'
echo $SLOT
export SLOT
./port.sh 0000:40:03.1
./port.sh 0000:40:03.2
./port.sh 0000:40:03.3  
./port.sh 0000:40:03.4

SLOT='Slot 7'
echo $SLOT
export SLOT
./port.sh 0000:00:03.1
./port.sh 0000:00:03.2
./port.sh 0000:00:03.3  
./port.sh 0000:00:03.4

SLOT='M.2_1'
echo $SLOT
export SLOT
./port.sh 0000:20:01.2

SLOT='M.2_2'
echo $SLOT
export SLOT
./port.sh 0000:20:01.3
