#!/bin/busybox sh

echo 'starting dd read blocksize=1M (max 32 NVME)'

for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31
do
  /c-payne/nvme_dd_read.sh $i &
done
while true; do sleep 10000; done
