#!/bin/busybox sh

MAINBOARD='Supermicro H12SSW-NTR / Supermicro H12SSW-iNR'
echo $MAINBOARD
export MAINBOARD

SLOT='(x8) NVME 0/1'
echo $SLOT
export SLOT
./port.sh 0000:c0:01.1
./port.sh 0000:c0:01.2

SLOT='(x8) NVME 2/3'
echo $SLOT
export SLOT
./port.sh 0000:c0:01.3
./port.sh 0000:c0:01.4

SLOT='(x8) NVME 4/5'
echo $SLOT
export SLOT
./port.sh 0000:80:03.1
./port.sh 0000:80:03.2

SLOT='(x8) NVME 6/7'
echo $SLOT
export SLOT
./port.sh 0000:80:03.3
./port.sh 0000:80:03.4

SLOT='(x8) NVME 8/9(SATA dual Port)'
echo $SLOT
export SLOT
./port.sh 0000:00:03.1
./port.sh 0000:00:03.2

SLOT='(x8) NVME 10/11'
echo $SLOT
export SLOT
./port.sh 0000:00:03.3
./port.sh 0000:00:03.4

SLOT='(x8) NVME 12/13(SATA dual Port'
echo $SLOT
export SLOT
./port.sh 0000:40:01.1
./port.sh 0000:40:01.2

SLOT='(x8) NVME 14/15'
echo $SLOT
export SLOT
./port.sh 0000:40:01.3
./port.sh 0000:40:01.4

SLOT='(x32) Left Riser Slot - lower x16'
echo $SLOT
export SLOT
./port.sh 0000:80:01.1
./port.sh 0000:80:01.2
./port.sh 0000:80:01.3  
./port.sh 0000:80:01.4

SLOT='(x32) Left Riser Slot - upper x16'
echo $SLOT
export SLOT
./port.sh 0000:c0:03.1
./port.sh 0000:c0:03.2
./port.sh 0000:c0:03.3  
./port.sh 0000:c0:03.4

SLOT='(x16) Right Riser Slot'
echo $SLOT
export SLOT
./port.sh 0000:00:01.1
./port.sh 0000:00:01.2
./port.sh 0000:00:01.3  
./port.sh 0000:00:01.4

SLOT='(x2) M.2 C1:'
echo $SLOT
export SLOT
./port.sh 0000:40:03.6

SLOT='(x2) M.2 C2:'
echo $SLOT
export SLOT
./port.sh 0000:40:03.7
