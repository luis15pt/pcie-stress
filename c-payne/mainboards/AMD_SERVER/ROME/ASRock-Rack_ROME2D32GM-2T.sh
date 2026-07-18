#!/bin/busybox sh

MAINBOARD='ASRock-Rack ROME2D32GM-2T'
echo $MAINBOARD
export MAINBOARD

SLOT='SLIM1'
echo $SLOT
export SLOT
./port.sh 0000:00:01.1
./port.sh 0000:00:01.2
./port.sh 0000:00:01.3  
./port.sh 0000:00:01.4

SLOT='SLIM2'
echo $SLOT
export SLOT
./port.sh 0000:20:03.1
./port.sh 0000:20:03.2
./port.sh 0000:20:03.3  
./port.sh 0000:20:03.4

SLOT='SLIM3'
echo $SLOT
export SLOT
./port.sh 0000:60:03.1
./port.sh 0000:60:03.2
./port.sh 0000:60:03.3  
./port.sh 0000:60:03.4

SLOT='SLIM4'
echo $SLOT
export SLOT
./port.sh 0000:40:01.1
./port.sh 0000:40:01.2
./port.sh 0000:40:01.3  
./port.sh 0000:40:01.4

SLOT='SLIM5'
echo $SLOT
export SLOT
./port.sh 0000:20:01.3  
./port.sh 0000:20:01.4

SLOT='SLIM6'
echo $SLOT
export SLOT
./port.sh 0000:80:01.1
./port.sh 0000:80:01.2
./port.sh 0000:80:01.3  
./port.sh 0000:80:01.4

SLOT='SLIM7'
echo $SLOT
export SLOT
./port.sh 0000:a0:03.1
./port.sh 0000:a0:03.2
./port.sh 0000:a0:03.3  
./port.sh 0000:a0:03.4

SLOT='SLIM8'
echo $SLOT
export SLOT
./port.sh 0000:e0:03.1
./port.sh 0000:e0:03.2
./port.sh 0000:e0:03.3  
./port.sh 0000:e0:03.4

SLOT='SLIM9'
echo $SLOT
export SLOT
./port.sh 0000:c0:01.1
./port.sh 0000:c0:01.2
./port.sh 0000:c0:01.3  
./port.sh 0000:c0:01.4

SLOT='SLIM10'
echo $SLOT
export SLOT
./port.sh 0000:c0:03.1
./port.sh 0000:c0:03.2
./port.sh 0000:c0:03.3  
./port.sh 0000:c0:03.4

SLOT='M.2'
echo $SLOT
export SLOT
./port.sh 0000:20:01.1
