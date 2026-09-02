#!/usr/bin/env python3
"""Substitute real GDDR VRAM temperatures into the gddr6_temps exporter's output.

Background: jjziets/gddr6_temps' `nvml_direct_access` reads VRAM/hotspot temps
via NVML, which returns placeholder values on GeForce Blackwell (RTX 5090
reports a constant VRAM_TEMP=8 / HOT_SPOT_TEMP=17). Its CLOCKS_THROTTLE_REASON
output, however, is real and worth keeping.

olealgoritme/gddr6 reads the per-module DRAM sensors directly from BAR space and
does produce real numbers, so this merges the two:

    nvml_direct_access  (cwd=RAW_DIR)  -->  RAW_DIR/metrics.txt
    gddr6 --per-module  (streamed)     -->  live per-module temps
                                        \\--> merged --> /metrics.txt --> :9500

Only the VRAM_TEMP / HOT_SPOT_TEMP values are rewritten; every other line is
passed through untouched, so existing Prometheus scrapes and dashboards keep
working with no config change.

A dead/off-bus GPU makes gddr6 emit garbage (a uniform 120C across an
impossible 16 modules - live cards have 8), so those readings are rejected and
the original value is left in place with gddr6_vram_valid=0.
"""
import os
import re
import subprocess
import sys
import threading
import time

RAW = os.environ.get("VRAM_RAW_DIR", "/run/gddr6-vram") + "/metrics.txt"
OUT = os.environ.get("VRAM_OUT", "/metrics.txt")
GDDR6 = os.environ.get("VRAM_TOOL", "/usr/local/bin/gddr6")
INTERVAL = float(os.environ.get("VRAM_MERGE_INTERVAL", "2"))

# pci bus as gddr6 prints it ("81:0:0") -> {"modules": [..], "ts": epoch}
live = {}
live_lock = threading.Lock()


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def uuid_map():
    """{'0000:81:00.0': 'GPU-xxxx'} from nvidia-smi (timeout-wrapped: a dead GPU hangs it)."""
    try:
        out = subprocess.run(
            ["timeout", "25", "nvidia-smi",
             "--query-gpu=pci.bus_id,uuid", "--format=csv,noheader"],
            capture_output=True, text=True, timeout=40).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    m = {}
    for line in out.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) == 2 and parts[1].startswith("GPU-"):
            m[parts[0].lower().replace("00000000:", "0000:")] = parts[1]
    return m


def norm(bus):
    """gddr6 '81:0:0' -> '0000:81:00.0'"""
    p = bus.split(":")
    if len(p) != 3:
        return None
    return "0000:%02x:%02x.%d" % (int(p[0], 16), int(p[1], 16), int(p[2]))


def reader():
    """Stream gddr6 --per-module forever, keeping `live` fresh."""
    dev_re = re.compile(r"pci=([0-9a-fA-F]+:[0-9a-fA-F]+:[0-9a-fA-F]+)")
    mod_re = re.compile(r"m(\d+)=\s*(\d+)")
    while True:
        order = []
        try:
            proc = subprocess.Popen(
                ["stdbuf", "-o0", GDDR6, "--per-module"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        except OSError as e:
            log("cannot start %s: %s" % (GDDR6, e))
            time.sleep(30)
            continue
        for chunk in iter(lambda: proc.stdout.read(4096), ""):
            for line in chunk.replace("\r", "\n").split("\n"):
                if line.startswith("Device:"):
                    m = dev_re.search(line)
                    if m:
                        b = norm(m.group(1))
                        if b and b not in order:
                            order.append(b)
                elif line.startswith("VRAM Temps:") and order:
                    # one flat list of m0..mN groups, in the Device: order
                    groups, cur = [], []
                    for mm in mod_re.finditer(line):
                        idx, val = int(mm.group(1)), int(mm.group(2))
                        if idx == 0 and cur:
                            groups.append(cur); cur = []
                        cur.append(val)
                    if cur:
                        groups.append(cur)
                    now = time.time()
                    with live_lock:
                        for bus, mods in zip(order, groups):
                            live[bus] = {"modules": mods, "ts": now}
        proc.wait()
        log("gddr6 exited (%s); restarting" % proc.returncode)
        time.sleep(5)


def value_for(bus):
    """(hotspot, valid) for a pci bus, or (None, False)."""
    with live_lock:
        e = live.get(bus)
        if not e:
            return None, False
        mods, ts = e["modules"], e["ts"]
    if time.time() - ts > 30:            # stale
        return None, False
    # dead-GPU garbage: impossible module count, or every module pegged at 120
    if len(mods) > 8 or (mods and all(v == 120 for v in mods)):
        return None, False
    if not mods or max(mods) <= 0 or max(mods) > 115:
        return None, False
    return max(mods), True


def merge_once(umap):
    try:
        with open(RAW) as f:
            raw = f.read()
    except OSError:
        return False
    by_uuid = {v: k for k, v in umap.items()}
    out, extra = [], []
    val_re = re.compile(r'^(DCGM_FI_DEV_(?:VRAM|HOT_SPOT)_TEMP\{[^}]*UUID="([^"]+)"[^}]*\})\s+(\S+)')
    seen = set()
    for line in raw.splitlines():
        m = val_re.match(line)
        if m:
            head, uuid, orig = m.group(1), m.group(2), m.group(3)
            bus = by_uuid.get(uuid)
            hot, ok = value_for(bus) if bus else (None, False)
            out.append("%s %s" % (head, hot if ok else orig))
            if bus and uuid not in seen:
                seen.add(uuid)
                extra.append('gddr6_vram_valid{gpu_uuid="%s",pci_bus_id="%s"} %d'
                             % (uuid, bus, 1 if ok else 0))
                with live_lock:
                    e = live.get(bus)
                if ok and e:
                    for i, v in enumerate(e["modules"]):
                        extra.append('gddr6_vram_module_temp_celsius'
                                     '{gpu_uuid="%s",pci_bus_id="%s",module="%d"} %d'
                                     % (uuid, bus, i, v))
        else:
            out.append(line)
    if extra:
        out.append("# HELP gddr6_vram_valid Whether the BAR-level GDDR reading is usable (0 = dead GPU or stale)")
        out.append("# TYPE gddr6_vram_valid gauge")
        out.append("# HELP gddr6_vram_module_temp_celsius Per-module GDDR temperature from BAR registers")
        out.append("# TYPE gddr6_vram_module_temp_celsius gauge")
        out.extend(extra)
    out.append("# HELP gddr6_vram_merge_timestamp_seconds Unix time of the last successful merge (staleness check)")
    out.append("# TYPE gddr6_vram_merge_timestamp_seconds gauge")
    out.append("gddr6_vram_merge_timestamp_seconds %d" % time.time())
    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(out) + "\n")
    os.replace(tmp, OUT)               # atomic: metrics_exporter never sees a partial file
    return True


def main():
    os.makedirs(os.path.dirname(RAW), exist_ok=True)
    threading.Thread(target=reader, daemon=True).start()
    umap, last_map = uuid_map(), time.time()
    log("vram-metrics-merge: raw=%s out=%s gpus=%d" % (RAW, OUT, len(umap)))
    warned = False
    while True:
        if time.time() - last_map > 300:
            new = uuid_map()
            if new:
                umap = new
            last_map = time.time()
        if not merge_once(umap) and not warned:
            log("waiting for %s (is nvml_direct_access running with cwd=%s?)"
                % (RAW, os.path.dirname(RAW)))
            warned = True
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
