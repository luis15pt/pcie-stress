#!/bin/busybox sh

MAINBOARD='ASRock-Rack GENOA2D24G-2L+'
echo $MAINBOARD
export MAINBOARD

SLOT='MCIO 1+2'
echo $SLOT
export SLOT
./port.sh 0000:00:01.1
./port.sh 0000:00:01.2
./port.sh 0000:00:01.3  
./port.sh 0000:00:01.4

SLOT='MCIO 3+4'
echo $SLOT
export SLOT
./port.sh 0000:20:01.1
./port.sh 0000:20:01.2
./port.sh 0000:20:01.3  
./port.sh 0000:20:01.4

SLOT='MCIO 5+6'
echo $SLOT
export SLOT
./port.sh 0000:40:01.1
./port.sh 0000:40:01.2
./port.sh 0000:40:01.3  
./port.sh 0000:40:01.4

SLOT='MCIO 7+8'
echo $SLOT
export SLOT
./port.sh 0000:60:01.1
./port.sh 0000:60:01.2
./port.sh 0000:60:01.3  
./port.sh 0000:60:01.4

SLOT='MCIO 9+10'
echo $SLOT
export SLOT
./port.sh 0000:20:03.1
./port.sh 0000:20:03.2
./port.sh 0000:20:03.3  
./port.sh 0000:20:03.4

SLOT='MCIO 11+12'
echo $SLOT
export SLOT
./port.sh 0000:80:01.1
./port.sh 0000:80:01.2
./port.sh 0000:80:01.3  
./port.sh 0000:80:01.4

SLOT='MCIO 13+14'
echo $SLOT
export SLOT
./port.sh 0000:a0:01.1
./port.sh 0000:a0:01.2
./port.sh 0000:a0:01.3  
./port.sh 0000:a0:01.4

SLOT='MCIO 15+16'
echo $SLOT
export SLOT
./port.sh 0000:c0:01.1
./port.sh 0000:c0:01.2
./port.sh 0000:c0:01.3  
./port.sh 0000:c0:01.4

SLOT='MCIO 17+18'
echo $SLOT
export SLOT
./port.sh 0000:e0:01.1
./port.sh 0000:e0:01.2
./port.sh 0000:e0:01.3  
./port.sh 0000:e0:01.4

SLOT='MCIO 19+20'
echo $SLOT
export SLOT
./port.sh 0000:c0:03.1
./port.sh 0000:c0:03.2
./port.sh 0000:c0:03.3  
./port.sh 0000:c0:03.4
