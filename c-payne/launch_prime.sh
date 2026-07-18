#!/bin/busybox sh

echo 'prime95'
echo ''
read -p "Press any key to start prime95... " -n1 -s
read -p "Press again... " -n1 -s
/bin/mprime -t
