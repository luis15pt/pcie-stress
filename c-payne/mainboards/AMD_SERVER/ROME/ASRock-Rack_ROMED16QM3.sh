#!/bin/busybox sh

MAINBOARD='ASRock-Rack ROMED16QM3'
echo $MAINBOARD
export MAINBOARD

SLOT='SLIM1/SLIM2'
echo $SLOT
export SLOT
./port.sh 0000:c0:01.1
./port.sh 0000:c0:01.2
./port.sh 0000:c0:01.3  
./port.sh 0000:c0:01.4

SLOT='SLIM3/SLIM4'
echo $SLOT
export SLOT
./port.sh 0000:80:03.1
./port.sh 0000:80:03.2
./port.sh 0000:80:03.3  
./port.sh 0000:80:03.4

SLOT='SLIM5/SLIM6'
echo $SLOT
export SLOT
./port.sh 0000:c0:03.1
./port.sh 0000:c0:03.2
./port.sh 0000:c0:03.3  
./port.sh 0000:c0:03.4

SLOT='SLIM7/SLIM8'
echo $SLOT
export SLOT
./port.sh 0000:80:01.1
./port.sh 0000:80:01.2
./port.sh 0000:80:01.3  
./port.sh 0000:80:01.4

SLOT='SLIM9/SLIM10'
echo $SLOT
export SLOT
./port.sh 0000:00:01.1
./port.sh 0000:00:01.2
./port.sh 0000:00:01.3  
./port.sh 0000:00:01.4

SLOT='SLIM11/SLIM12'
echo $SLOT
export SLOT
./port.sh 0000:40:03.1
./port.sh 0000:40:03.2
./port.sh 0000:40:03.3  
./port.sh 0000:40:03.4

SLOT='OCP 3.0 mezzanine'
echo $SLOT
export SLOT
./port.sh 0000:40:01.1
./port.sh 0000:40:01.2
./port.sh 0000:40:01.3  
./port.sh 0000:40:01.4

SLOT='x16 Slot (electrical x8)'
echo $SLOT
export SLOT
./port.sh 0000:00:03.1
./port.sh 0000:00:03.2

SLOT='M.2_1'
echo $SLOT
export SLOT
./port.sh 0000:00:03.4

SLOT='M.2_2'
echo $SLOT
export SLOT
./port.sh 0000:00:03.3
