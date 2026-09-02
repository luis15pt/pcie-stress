#!/bin/bash
# Supervises the three parts of the :9500 VRAM metrics pipeline:
#   nvml_direct_access  (cwd=/run/gddr6-vram) -> /run/gddr6-vram/metrics.txt  [throttle reasons: real]
#   vram-metrics-merge.py                     -> /metrics.txt                [VRAM temps: real, from gddr6]
#   metrics_exporter    (cwd=/)               -> serves /metrics.txt on :9500
set -u
RAW_DIR=/run/gddr6-vram
mkdir -p "$RAW_DIR"

# Two writers to /metrics.txt is a silent data-corruption mode, and the unit's
# Conflicts= only protects us if the INSTALLED unit file is current (it was not,
# on one host, for weeks). Check at runtime as well.
if systemctl is-active --quiet gddr6-metrics-exporter.service 2>/dev/null; then
  echo "REFUSING TO START: gddr6-metrics-exporter.service is active and would also write /metrics.txt" >&2
  echo "  fix: sudo systemctl disable --now gddr6-metrics-exporter" >&2
  exit 1
fi
if command -v ss >/dev/null && ss -lntH 2>/dev/null | grep -q ':9500 '; then
  echo "REFUSING TO START: something is already listening on :9500" >&2
  ss -lntpH 2>/dev/null | grep ':9500 ' >&2
  exit 1
fi

cleanup() { pkill -P $$ 2>/dev/null; exit 0; }
trap cleanup SIGTERM SIGINT

# 1. raw producer, writing into RAW_DIR instead of /
( cd "$RAW_DIR" && while true; do /usr/local/bin/nvml_direct_access; sleep 2; done ) &

# 2. merger: real VRAM temps in, everything else passed through
( while true; do VRAM_RAW_DIR="$RAW_DIR" /usr/local/bin/vram-metrics-merge.py; sleep 5; done ) &

# 3. http server on :9500, reading ./metrics.txt from /
( cd / && while true; do /usr/local/bin/metrics_exporter; sleep 2; done ) &

wait
