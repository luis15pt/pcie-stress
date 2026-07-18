#!/bin/busybox sh

MAINBOARD='ASRock-Rack SP2C741D32G-2L+'
echo $MAINBOARD
export MAINBOARD

SLOT='MCIO 1+2'
echo $SLOT
export SLOT
./port.sh 0000:15:01.0
./port.sh 0000:15:03.0
./port.sh 0000:15:05.0  
./port.sh 0000:15:07.0

SLOT='MCIO 3+4'
echo $SLOT
export SLOT
./port.sh 0000:3f:01.0
./port.sh 0000:3f:03.0
./port.sh 0000:3f:05.0  
./port.sh 0000:3f:07.0

SLOT='MCIO 5+6'
echo $SLOT
export SLOT
./port.sh 0000:69:01.0
./port.sh 0000:69:03.0
./port.sh 0000:69:05.0  
./port.sh 0000:69:07.0

SLOT='MCIO 7+8'
echo $SLOT
export SLOT
./port.sh 0000:bd:01.0
./port.sh 0000:bd:03.0
./port.sh 0000:bd:05.0  
./port.sh 0000:bd:07.0

SLOT='MCIO 9+10'
echo $SLOT
export SLOT
./port.sh 0000:93:01.0
./port.sh 0000:93:03.0
./port.sh 0000:93:05.0  
./port.sh 0000:93:07.0

SLOT='MCIO 11+12'
echo $SLOT
export SLOT
./port.sh 0001:15:01.0
./port.sh 0001:15:03.0
./port.sh 0001:15:05.0  
./port.sh 0001:15:07.0

SLOT='MCIO 13+14'
echo $SLOT
export SLOT
./port.sh 0001:3f:01.0
./port.sh 0001:3f:03.0
./port.sh 0001:3f:05.0  
./port.sh 0001:3f:07.0

SLOT='MCIO 15+16'
echo $SLOT
export SLOT
./port.sh 0001:69:01.0
./port.sh 0001:69:03.0
./port.sh 0001:69:05.0  
./port.sh 0001:69:07.0

SLOT='MCIO 17+18'
echo $SLOT
export SLOT
./port.sh 0001:bd:01.0
./port.sh 0001:bd:03.0
./port.sh 0001:bd:05.0  
./port.sh 0001:bd:07.0

SLOT='MCIO 19+20'
echo $SLOT
export SLOT
./port.sh 0001:93:01.0
./port.sh 0001:93:03.0
./port.sh 0001:93:05.0  
./port.sh 0001:93:07.0

SLOT='MCIO 21'
echo $SLOT
export SLOT
./port.sh 0001:00:05.0
./port.sh 0001:00:07.0

SLOT='MCIO 22'
echo $SLOT
export SLOT
./port.sh 0000:00:08.0
./port.sh 0000:00:0a.0

