#!/bin/bash
# Supervises the three parts of the :9500 VRAM metrics pipeline:
#   nvml_direct_access  (cwd=/run/gddr6-vram) -> /run/gddr6-vram/metrics.txt  [throttle reasons: real]
#   vram-metrics-merge.py                     -> /metrics.txt                [VRAM temps: real, from gddr6]
#   metrics_exporter    (cwd=/)               -> serves /metrics.txt on :9500
set -u
RAW_DIR=/run/gddr6-vram
mkdir -p "$RAW_DIR"

cleanup() { pkill -P $$ 2>/dev/null; exit 0; }
trap cleanup SIGTERM SIGINT

# 1. raw producer, writing into RAW_DIR instead of /
( cd "$RAW_DIR" && while true; do /usr/local/bin/nvml_direct_access; sleep 2; done ) &

# 2. merger: real VRAM temps in, everything else passed through
( while true; do VRAM_RAW_DIR="$RAW_DIR" /usr/local/bin/vram-metrics-merge.py; sleep 5; done ) &

# 3. http server on :9500, reading ./metrics.txt from /
( cd / && while true; do /usr/local/bin/metrics_exporter; sleep 2; done ) &

wait
