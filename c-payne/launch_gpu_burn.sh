#!/bin/busybox sh

echo 'waiting 60 seconds for stress test to claim vram'
sleep 60
/bin/gpu_burn -tc 10000000

