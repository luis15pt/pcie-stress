#!/bin/busybox sh

MAINBOARD='generic Threadripper WRX90'
echo $MAINBOARD
export MAINBOARD

SLOT='generic'
export SLOT

./port.sh 0000:00:01.1
./port.sh 0000:00:01.2
./port.sh 0000:00:01.3  
./port.sh 0000:00:01.4
./port.sh 0000:00:03.1
./port.sh 0000:00:03.2
./port.sh 0000:00:03.3  
./port.sh 0000:00:03.4

./port.sh 0000:20:01.1
./port.sh 0000:20:01.2
./port.sh 0000:20:01.3  
./port.sh 0000:20:01.4
./port.sh 0000:20:03.1
./port.sh 0000:20:03.2
./port.sh 0000:20:03.3  
./port.sh 0000:20:03.4

./port.sh 0000:40:01.1
./port.sh 0000:40:01.2
./port.sh 0000:40:01.3  
./port.sh 0000:40:01.4
./port.sh 0000:40:03.1
./port.sh 0000:40:03.2
./port.sh 0000:40:03.3  
./port.sh 0000:40:03.4

./port.sh 0000:60:01.1
./port.sh 0000:60:01.2
./port.sh 0000:60:01.3  
./port.sh 0000:60:01.4
./port.sh 0000:60:03.1
./port.sh 0000:60:03.2
./port.sh 0000:60:03.3  
./port.sh 0000:60:03.4

./port.sh 0000:80:01.1
./port.sh 0000:80:01.2
./port.sh 0000:80:01.3  
./port.sh 0000:80:01.4
./port.sh 0000:80:03.1
./port.sh 0000:80:03.2
./port.sh 0000:80:03.3  
./port.sh 0000:80:03.4

./port.sh 0000:a0:01.1
./port.sh 0000:a0:01.2
./port.sh 0000:a0:01.3  
./port.sh 0000:a0:01.4
./port.sh 0000:a0:03.1
./port.sh 0000:a0:03.2
./port.sh 0000:a0:03.3  
./port.sh 0000:a0:03.4

./port.sh 0000:c0:01.1
./port.sh 0000:c0:01.2
./port.sh 0000:c0:01.3  
./port.sh 0000:c0:01.4
./port.sh 0000:c0:03.1
./port.sh 0000:c0:03.2
./port.sh 0000:c0:03.3  
./port.sh 0000:c0:03.4

./port.sh 0000:e0:01.1
./port.sh 0000:e0:01.2
./port.sh 0000:e0:01.3  
./port.sh 0000:e0:01.4
./port.sh 0000:e0:03.1
./port.sh 0000:e0:03.2
./port.sh 0000:e0:03.3  
./port.sh 0000:e0:03.4

