#!/bin/busybox sh

MAINBOARD='ASUS Pro WS WRX90E-SAGE SE'
echo $MAINBOARD
export MAINBOARD

SLOT='Slot 1 (closest to CPU)'
echo $SLOT
export SLOT
./port.sh 0000:e0:01.1
./port.sh 0000:e0:01.2
./port.sh 0000:e0:01.3  
./port.sh 0000:e0:01.4

SLOT='Slot 2'
echo $SLOT
export SLOT
./port.sh 0000:c0:01.1
./port.sh 0000:c0:01.2
./port.sh 0000:c0:01.3  
./port.sh 0000:c0:01.4

SLOT='Slot 3'
echo $SLOT
export SLOT
./port.sh 0000:00:01.1
./port.sh 0000:00:01.2
./port.sh 0000:00:01.3  
./port.sh 0000:00:01.4

SLOT='Slot 4'
echo $SLOT
export SLOT
./port.sh 0000:20:01.1
./port.sh 0000:20:01.2
./port.sh 0000:20:01.3  
./port.sh 0000:20:01.4

SLOT='Slot 5'
echo $SLOT
export SLOT
./port.sh 0000:c0:03.1 #?
./port.sh 0000:c0:03.2 #?
./port.sh 0000:c0:03.3 #?
./port.sh 0000:c0:03.4 #?

SLOT='Slot 6(x8)'
echo $SLOT
export SLOT
./port.sh 0000:e0:03.1 #?
./port.sh 0000:e0:03.2 #?

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
./port.sh 0000:20:03.2 #?

SLOT='M.2_2'
echo $SLOT
export SLOT
./port.sh 0000:20:03.3 #?

SLOT='M.2_3'
echo $SLOT
export SLOT
./port.sh 0000:e0:03.3 #?

SLOT='M.2_4'
echo $SLOT
export SLOT
./port.sh 0000:e0:03.4 #?
