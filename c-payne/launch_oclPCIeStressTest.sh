#!/bin/busybox sh

echo 'starting 5 stress test threads per GPU(max 32 GPUs)'

for i in 1 2 3 4 5
do
  for j in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31
  do
    /bin/oclPCIeStressTest 0 $j &
  done
done
while true; do sleep 10000; done

