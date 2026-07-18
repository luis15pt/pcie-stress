#!/bin/busybox sh

MAINBOARD='Supermicro H13SSL-N / H13SSL-NT'
echo $MAINBOARD
export MAINBOARD

SLOT='(x16) Slot 5 (closest to CPU)'
echo $SLOT
export SLOT
./port.sh 0000:40:01.1
./port.sh 0000:40:01.2
./port.sh 0000:40:01.3  
./port.sh 0000:40:01.4

SLOT='( x8) Slot 4'
echo $SLOT
export SLOT
./port.sh 0000:80:03.2
./port.sh 0000:80:03.3  
./port.sh 0000:80:03.4

SLOT='(x16) Slot 3'
echo $SLOT
export SLOT
./port.sh 0000:00:03.1
./port.sh 0000:00:03.2
./port.sh 0000:00:03.3  
./port.sh 0000:00:03.4

SLOT='( x8) Slot 2'
echo $SLOT
export SLOT
./port.sh 0000:80:03.1

SLOT='(x16) Slot 1'
echo $SLOT
export SLOT
./port.sh 0000:00:01.1
./port.sh 0000:00:01.2
./port.sh 0000:00:01.3  
./port.sh 0000:00:01.4

SLOT='( x8) JMCIO 1'
echo $SLOT
export SLOT
./port.sh 0000:80:01.1
./port.sh 0000:80:01.2

SLOT='( x8) JMCIO 2'
echo $SLOT
export SLOT
./port.sh 0000:80:01.3
./port.sh 0000:80:01.4

SLOT='( x8) JMCIO 3'
echo $SLOT
export SLOT
./port.sh 0000:c0:01.1
./port.sh 0000:c0:01.2

SLOT='( x4) M.2-H1'
echo $SLOT
export SLOT
./port.sh 0000:40:03.2

SLOT='( x4) M.2-H2'
echo $SLOT
export SLOT
./port.sh 0000:40:03.3
