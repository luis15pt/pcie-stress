#!/bin/busybox sh

if test -e "/dev/nvme$1n1"; then
  echo reading from /dev/nvme$1n1 blocksize=1M
  while true; do
    /bin/dd if=/dev/nvme$1n1 of=/dev/zero bs=1M status=progress iflag=direct 2>&1 | tr '\r' '\n'
  done
fi  


