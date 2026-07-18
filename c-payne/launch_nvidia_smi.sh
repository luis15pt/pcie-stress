#!/bin/busybox sh

clear
/bin/nvidia-smi | awk 'NR==1' RS='\n\n'
sleep 10
