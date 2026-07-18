#!/bin/busybox sh

MAINBOARD='ASRock WRX90 WS EVO'
echo $MAINBOARD
export MAINBOARD

SLOT='Slot 1 (closest to CPU)'
echo $SLOT
export SLOT
./port.sh 0000:c0:01.1
./port.sh 0000:c0:01.2
./port.sh 0000:c0:01.3  
./port.sh 0000:c0:01.4

SLOT='Slot 2'
echo $SLOT
export SLOT
./port.sh 0000:80:01.1
./port.sh 0000:80:01.2
./port.sh 0000:80:01.3  
./port.sh 0000:80:01.4

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
./port.sh 0000:40:01.1
./port.sh 0000:40:01.2
./port.sh 0000:40:01.3  
./port.sh 0000:40:01.4

SLOT='Slot 5'
echo $SLOT
export SLOT
./port.sh 0000:c0:03.1
./port.sh 0000:c0:03.2
./port.sh 0000:c0:03.3  
./port.sh 0000:c0:03.4

SLOT='Slot 6(x8)'
echo $SLOT
export SLOT
./port.sh 0000:80:03.3
./port.sh 0000:80:03.4

SLOT='Slot 7'
echo $SLOT
export SLOT
./port.sh 0000:00:03.1
./port.sh 0000:00:03.2
./port.sh 0000:00:03.3  
./port.sh 0000:00:03.4

SLOT='M.2'
echo $SLOT
export SLOT
./port.sh 0000:80:03.2

SLOT='MCIO1'
echo $SLOT
export SLOT
./port.sh 0000:40:03.1

SLOT='MCIO2'
echo $SLOT
export SLOT
./port.sh 0000:40:03.2

SLOT='SLIMSAS1'
echo $SLOT
export SLOT
./port.sh 0000:40:03.3
