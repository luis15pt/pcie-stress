#!/bin/bash
# Install the GPU dropout incident recorder as a systemd service.
# Usage: sudo host/install.sh [--journald-cap]
#   --journald-cap  also set SystemMaxUse=2G in journald.conf (stops AER/NVMe
#                   log spam from rotating GPU evidence out of the journal)
set -eu

cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0"; exit 1; }

install -m 755 gpu-dropout-recorder.sh /usr/local/bin/gpu-dropout-recorder.sh
install -m 755 gpu-fan-control.sh /usr/local/bin/gpu-fan-control.sh
install -m 755 vram-metrics-merge.py /usr/local/bin/vram-metrics-merge.py
install -m 755 vram-metrics-supervisor.sh /usr/local/bin/vram-metrics-supervisor.sh
install -m 644 vram-metrics.service /etc/systemd/system/vram-metrics.service
install -m 644 gpu-fan-control.service /etc/systemd/system/gpu-fan-control.service
if [ ! -f /etc/gpu-fan-control.conf ]; then install -m 644 gpu-fan-control.conf /etc/gpu-fan-control.conf; fi
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
# same stale-code trap as vram-metrics: `enable --now` starts a stopped service
# but is a NO-OP against a running one, so a freshly installed script would not
# take effect until the next reboot. Restart explicitly.
systemctl enable gpu-dropout-recorder.service >/dev/null 2>&1 || true
systemctl restart gpu-dropout-recorder.service || echo "WARN: gpu-dropout-recorder.service failed to start"

# vram-metrics: enable AND unconditionally restart. `install` replaces the file
# on disk but a running Python interpreter keeps executing the old code from
# memory - that is exactly how one host ran a stale merge.py for weeks. A brief
# metrics gap is the right trade for knowing what is actually running.
systemctl enable vram-metrics.service >/dev/null 2>&1 || true
systemctl restart vram-metrics.service || echo "WARN: vram-metrics.service failed to start"

# gpu-fan-control: only enable once FAN_SET_CMD is known, otherwise it logs
# "FAN_SET_CMD not configured" every 5s forever.
if grep -q '^[[:space:]]*FAN_SET_CMD=' /etc/gpu-fan-control.conf 2>/dev/null; then
  systemctl enable gpu-fan-control.service >/dev/null 2>&1 || true
  systemctl restart gpu-fan-control.service || echo "WARN: gpu-fan-control.service failed to start"
else
  echo "gpu-fan-control NOT enabled: FAN_SET_CMD unset in /etc/gpu-fan-control.conf"
  echo "  discover it with: sudo /usr/local/bin/gpu-fan-control.sh probe"
fi

sleep 3
echo ""
echo "=== service state ==="
for u in gpu-dropout-recorder vram-metrics gpu-fan-control; do
  printf "  %-22s %s\n" "$u" "$(systemctl is-active $u 2>/dev/null) / $(systemctl is-enabled $u 2>/dev/null)"
done
# drift check: warn if an installed unit differs from the repo copy
for u in gpu-dropout-recorder gpu-fan-control vram-metrics; do
  if [ -f "$u.service" ] && ! cmp -s "$u.service" "/etc/systemd/system/$u.service"; then
    echo "  WARN: /etc/systemd/system/$u.service differs from the repo copy"
  fi
done
echo ""
echo "telemetry ring: /var/log/gpu-recorder/telemetry.csv"
echo "test capture:   sudo kill -USR1 \$(systemctl show -p MainPID --value gpu-dropout-recorder)"
