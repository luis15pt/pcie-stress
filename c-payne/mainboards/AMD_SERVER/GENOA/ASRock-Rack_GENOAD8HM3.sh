#!/bin/busybox sh

MAINBOARD='ASRock-Rack GENOAD8HM3'
echo $MAINBOARD
export MAINBOARD

SLOT='MCIO 1+2'
echo $SLOT
export SLOT
./port.sh 0000:c0:01.1
./port.sh 0000:c0:01.2
./port.sh 0000:c0:01.3  
./port.sh 0000:c0:01.4

SLOT='MCIO 3+4 (4 is lane reversed)'
echo $SLOT
export SLOT
./port.sh 0000:80:01.1
./port.sh 0000:80:01.2
./port.sh 0000:80:01.3  
./port.sh 0000:80:01.4

SLOT='MCIO 5+6 (5 is lane reversed)'
echo $SLOT
export SLOT
./port.sh 0000:40:01.1
./port.sh 0000:40:01.2
./port.sh 0000:40:01.3  
./port.sh 0000:40:01.4

SLOT='MCIO 7+8'
echo $SLOT
export SLOT
./port.sh 0000:00:01.1
./port.sh 0000:00:01.2
./port.sh 0000:00:01.3  
./port.sh 0000:00:01.4

SLOT='PCIE 1'
echo $SLOT
export SLOT
./port.sh 0000:c0:03.1
./port.sh 0000:c0:03.2
./port.sh 0000:c0:03.3  
./port.sh 0000:c0:03.4

SLOT='PCIE 2 (next to PCIE 3)'
echo $SLOT
export SLOT
./port.sh 0000:00:03.1
./port.sh 0000:00:03.2
./port.sh 0000:00:03.3  
./port.sh 0000:00:03.4

SLOT='PCIE 3 (x8)'
echo $SLOT
export SLOT
./port.sh 0000:40:03.1
./port.sh 0000:40:03.2

SLOT='OCP'
echo $SLOT
export SLOT
./port.sh 0000:80:03.1
./port.sh 0000:80:03.2
./port.sh 0000:80:03.3
./port.sh 0000:80:03.4

SLOT='M.2 1'
echo $SLOT
export SLOT
./port.sh 0000:40:03.3

SLOT='M.2 2'
echo $SLOT
export SLOT
./port.sh 0000:40:03.4

