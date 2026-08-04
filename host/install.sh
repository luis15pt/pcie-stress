#!/bin/bash
# Install the GPU dropout incident recorder as a systemd service.
# Usage: sudo host/install.sh [--journald-cap]
#   --journald-cap  also set SystemMaxUse=2G in journald.conf (stops AER/NVMe
#                   log spam from rotating GPU evidence out of the journal)
set -eu

cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0"; exit 1; }

install -m 755 gpu-dropout-recorder.sh /usr/local/bin/gpu-dropout-recorder.sh
install -m 644 gpu-dropout-recorder.service /etc/systemd/system/gpu-dropout-recorder.service
if [ ! -f /etc/gpu-dropout-recorder.conf ]; then
  install -m 600 gpu-dropout-recorder.conf /etc/gpu-dropout-recorder.conf
  echo "installed default config -> /etc/gpu-dropout-recorder.conf (edit WEBHOOK_URL!)"
else
  echo "kept existing /etc/gpu-dropout-recorder.conf"
fi

if [ "${1:-}" = "--journald-cap" ]; then
  if ! grep -q '^SystemMaxUse=' /etc/systemd/journald.conf 2>/dev/null; then
    printf 'SystemMaxUse=2G\n' >> /etc/systemd/journald.conf
    systemctl restart systemd-journald
    echo "journald capped at 2G"
  else
    echo "journald SystemMaxUse already set; not touching it"
  fi
fi

systemctl daemon-reload
systemctl enable --now gpu-dropout-recorder.service
sleep 2
systemctl --no-pager status gpu-dropout-recorder.service | head -8
echo ""
echo "telemetry ring: /var/log/gpu-recorder/telemetry.csv"
echo "test capture:   sudo kill -USR1 \$(systemctl show -p MainPID --value gpu-dropout-recorder)"
