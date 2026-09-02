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
import collections
import json
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


# bumped by hand on every behavioural change; exported as vram_metrics_merge_info
VERSION = "2026.09.02-3"


def _self_sha():
    """sha256 of this file, so the running code is identifiable in Prometheus."""
    try:
        import hashlib
        with open(__file__, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()[:16]
    except OSError:
        return "unknown"


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
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except OSError as e:
            log("cannot start %s: %s" % (GDDR6, e))
            time.sleep(30)
            continue
        # os.read returns as soon as ANY bytes are available; the buffered
        # proc.stdout.read(4096) instead BLOCKS until it has 4096 chars, which
        # silently re-introduced the very sampling lag `stdbuf -o0` removes (at
        # ~550 B per refresh cycle that is seconds of delay, so temps recorded
        # against a dropout timestamp were not the temps at that instant).
        # `pending` carries the trailing partial line across reads: a chunk
        # boundary landing mid-"VRAM Temps:" line used to parse as a short
        # module group and corrupt the readings with no error.
        fd = proc.stdout.fileno()
        pending = ""
        while True:
            try:
                buf = os.read(fd, 4096)
            except OSError:
                break
            if not buf:
                break
            pending += buf.decode("utf-8", "replace")
            parts = pending.replace("\r", "\n").split("\n")
            pending = parts.pop()          # keep the incomplete tail
            for line in parts:
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
    """(hotspot_max, mean, valid) for a pci bus, or (None, None, False)."""
    with live_lock:
        e = live.get(bus)
        if not e:
            return None, None, False
        mods, ts = e["modules"], e["ts"]
    if time.time() - ts > 30:            # stale
        return None, None, False
    # dead-GPU garbage: impossible module count, or every module pegged at 120
    if len(mods) > 8 or (mods and all(v == 120 for v in mods)):
        return None, None, False
    if not mods or max(mods) <= 0 or max(mods) > 115:
        return None, None, False
    return max(mods), round(sum(mods) / len(mods)), True


# --------------------------------------------------------------------------
# Junction (hotspot) temperature - see host/gputemps.sha for the pinned tool.
#
# Junction is the vendor's stated best early indicator of a thermally-failing
# 5090 ("any GPU over 100C junction is due for service") and NO NVIDIA
# interface exposes it: NVML enumerates exactly one thermal sensor and DCGM has
# no junction field. It comes from BAR0 MMIO instead, which means the number is
# only as trustworthy as a third-party register offset - so every reading goes
# through junction_gate() before it is allowed to become a metric.
#
# One process per PCI address, NOT one process for all GPUs. The tool emits the
# true NVML index (verified in monitor.c: gpu->index is the value passed to
# nvmlDeviceGetHandleByIndex), so a single process would in fact attribute
# correctly today - but per-device is correct by construction whatever upstream
# does next, and it isolates failures: on Juno the dead card's BDF makes the
# tool exit with "Invalid device selector", which breaks only that one reader
# instead of every reading on the host.
JUNCTION_TOOL = os.environ.get("JUNCTION_TOOL", "/usr/local/bin/gputemps")
# observe = publish junction metrics but leave DCGM_FI_DEV_HOT_SPOT_TEMP alone
# authoritative = HOT_SPOT_TEMP carries junction (P3, announced separately)
# off = no readers at all
JUNCTION_MODE = os.environ.get("JUNCTION_MODE", "observe")
# 1000ms deliberately. The tool allows 50ms, but three concurrent BAR readers
# at high rate is an unnecessary experiment on production cards and the ~1C
# truncation makes sub-second sampling pointless.
JUNCTION_REFRESH_MS = os.environ.get("JUNCTION_REFRESH_MS", "1000")
JUNCTION_STALE = float(os.environ.get("JUNCTION_STALE", "15"))
JUNCTION_HARD_STALE = float(os.environ.get("JUNCTION_HARD_STALE", "60"))
JUNCTION_CORE_TOL = float(os.environ.get("JUNCTION_CORE_TOL", "3"))
# 125, NOT the GDDR reader's 115: 100-110C junction is the exact alarm band
# this exists to detect, so reusing the GDDR ceiling would discard the signal.
JUNCTION_MAX = float(os.environ.get("JUNCTION_MAX", "125"))
JUNCTION_DELTA_FLAG = float(os.environ.get("JUNCTION_DELTA_FLAG", "40"))
JUNCTION_FROZEN_SECS = float(os.environ.get("JUNCTION_FROZEN_SECS", "300"))
JUNCTION_FROZEN_CORE_MOVE = float(os.environ.get("JUNCTION_FROZEN_CORE_MOVE", "10"))
JUNCTION_MISMATCH_LATCH = int(os.environ.get("JUNCTION_MISMATCH_LATCH", "5"))
JUNCTION_RETRUST = int(os.environ.get("JUNCTION_RETRUST", "10"))
CORE_REF_INTERVAL = float(os.environ.get("JUNCTION_CORE_REF_INTERVAL", "2"))
GPUTEMPS_BUILD = os.environ.get("JUNCTION_BUILD", "/opt/gputemps/BUILD")

jlive = {}                       # bdf -> {"core","junction","vram","index","ts"}
jhist = {}                       # bdf -> {"value","since","core_at"}
jstats = {}                      # bdf -> counters + stderr ring
jlock = threading.Lock()         # NEVER share live_lock: the readers must not
                                 # block each other or the GDDR reader
coreref = {}                     # bdf -> {"core","tlimit","ts"}
coreref_lock = threading.Lock()
# One index shift would corrupt every series at once, so trust is global.
jtrust = {"trusted": 1, "bad": 0, "good": 0}


def jstat(bdf):
    st = jstats.get(bdf)
    if st is None:
        st = {"restarts": 0, "parse_errors": 0, "up": 0,
              "stderr": collections.deque(maxlen=20)}
        jstats[bdf] = st
    return st


def tool_build_info():
    """{commit, binsha256, driver} from the BUILD stamp the build script writes."""
    info = {"commit": "unknown", "sha256": "unknown", "driver_at_build": "unknown"}
    try:
        with open(GPUTEMPS_BUILD) as f:
            for line in f:
                k, _, v = line.partition(":")
                v = v.strip()
                if k == "commit":
                    info["commit"] = v[:12]
                elif k == "binsha256":
                    info["sha256"] = v[:16]
                elif k == "driver":
                    info["driver_at_build"] = v
    except OSError:
        pass
    return info


def core_ref_sampler():
    """Independent core temperature + official T.Limit, for cross-checking.

    The raw exporter publishes no core temperature, so without this there is
    nothing to validate junction attribution against. nvidia-smi is
    timeout-wrapped because it hangs against a dead GPU; a card that has fallen
    off the bus simply drops out of the output, which is what we want.
    """
    while True:
        try:
            out = subprocess.run(
                ["timeout", "20", "nvidia-smi",
                 "--query-gpu=pci.bus_id,temperature.gpu,temperature.gpu.tlimit",
                 "--format=csv,noheader,nounits"],
                capture_output=True, text=True, timeout=30).stdout
        except (OSError, subprocess.TimeoutExpired):
            out = ""
        now = time.time()
        fresh = {}
        for line in out.splitlines():
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 3:
                continue
            bdf = parts[0].lower()
            if bdf.startswith("00000000:"):
                bdf = "0000:" + bdf[9:]
            try:
                core = int(parts[1])
            except ValueError:
                continue
            try:
                tlimit = int(parts[2])
            except ValueError:
                tlimit = None
            fresh[bdf] = {"core": core, "tlimit": tlimit, "ts": now}
        if fresh:
            with coreref_lock:
                coreref.update(fresh)
        time.sleep(CORE_REF_INTERVAL)


def _drain_stderr(proc, st):
    """Keep the tool's warnings, do not discard them.

    'unsupported device / falling back to profile' on stderr is precisely how
    you learn the 5090 profile did not match. Sending it to DEVNULL is how you
    trust wrong BAR offsets for a month.
    """
    try:
        for raw in proc.stderr:
            msg = raw.decode("utf-8", "replace").strip()
            if msg:
                st["stderr"].append(msg)
                log("gputemps stderr: %s" % msg[:200])
    except (OSError, ValueError):
        pass


def junction_reader(bdf):
    """Stream `gputemps --json --device <bdf>` forever, keeping jlive fresh."""
    st = jstat(bdf)
    fails = 0
    while True:
        try:
            proc = subprocess.Popen(
                ["stdbuf", "-o0", JUNCTION_TOOL, "--json",
                 "--refresh-ms", str(JUNCTION_REFRESH_MS), "--device", bdf],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError as e:
            log("cannot start %s: %s" % (JUNCTION_TOOL, e))
            time.sleep(min(5 * (2 ** min(fails, 6)), 300))
            fails += 1
            continue
        st["up"] = 1
        threading.Thread(target=_drain_stderr, args=(proc, st),
                         daemon=True).start()
        # A child that stops producing without exiting would otherwise leave
        # readline() blocked forever and the metric frozen at its last value.
        threading.Thread(target=_junction_watchdog, args=(proc, bdf),
                         daemon=True).start()
        got = 0
        # JSON Lines: newline-terminated, so readline returns as soon as a
        # record lands. (Unlike a fixed-size read, which blocks for the full
        # request - the bug that used to lag the GDDR reader by seconds.)
        for raw in proc.stdout:
            try:
                obj = json.loads(raw.decode("utf-8", "replace"))
                gpus = obj["gpus"]
            except (ValueError, KeyError, TypeError):
                # counted, never guessed: makes the next upstream schema
                # rewrite visible instead of silently mis-parsed
                st["parse_errors"] += 1
                continue
            if not gpus:
                continue
            g = gpus[0]
            with jlock:
                jlive[bdf] = {"core": g.get("core"),
                              "junction": g.get("junction"),
                              "vram": g.get("vram"),
                              "index": g.get("index"),
                              "ts": time.time()}
            got += 1
        proc.wait()
        st["up"] = 0
        st["restarts"] += 1
        with jlock:
            jlive.pop(bdf, None)
        if got:
            fails = 0                     # it worked, so this was a crash
        # Escalating, not flat: a permanently incompatible tool (or a dead
        # card, whose BDF the tool rejects outright) must not respawn a root
        # process every 5s forever.
        wait = min(5 * (2 ** min(fails, 6)), 300)
        fails += 1
        tail = "; last stderr: %s" % st["stderr"][-1] if st["stderr"] else ""
        log("gputemps[%s] exited rc=%s after %d samples; retry in %ds%s"
            % (bdf, proc.returncode, got, wait, tail))
        time.sleep(wait)


def _junction_watchdog(proc, bdf):
    while proc.poll() is None:
        time.sleep(5)
        with jlock:
            e = jlive.get(bdf)
        if e and time.time() - e["ts"] > JUNCTION_HARD_STALE:
            log("gputemps[%s] stopped producing for >%ds; killing to respawn"
                % (bdf, JUNCTION_HARD_STALE))
            try:
                proc.kill()
            except OSError:
                pass
            return


def junction_gate(sample, ref, hist, now=None,
                  tol=None, jmax=None, stale=None):
    """Decide whether one junction sample may become a metric.

    Pure function of its arguments so it can be table-tested without hardware,
    which matters because this predicate is the whole safety argument for
    publishing a third-party register read as a service-decision signal.

    Returns (valid, reason, flags). reason is None when valid.
    """
    now = time.time() if now is None else now
    tol = JUNCTION_CORE_TOL if tol is None else tol
    jmax = JUNCTION_MAX if jmax is None else jmax
    stale = JUNCTION_STALE if stale is None else stale
    flags = []

    if not sample:
        return False, "no_sample", flags
    if now - sample.get("ts", 0) > stale:
        return False, "stale", flags

    core_tool = sample.get("core")
    if core_tool is None:
        # without the tool's own core reading there is nothing to verify the
        # attribution against, so the junction value is unattributable
        return False, "no_core", flags

    core_ref = (ref or {}).get("core")
    if core_ref is not None and abs(core_tool - core_ref) > tol:
        return False, "core_mismatch", flags

    j = sample.get("junction")
    if j is None:
        return False, "junction_null", flags
    if j <= 0:
        return False, "junction_zero", flags
    if j < core_tool - 1:
        # junction is a hotspot on the same die; below core means the wrong
        # profile or offset. -1 absorbs the tool's integer truncation.
        return False, "below_core", flags
    if j > jmax:
        return False, "impossible", flags

    # Non-fatal on purpose: a large delta is what a degrading thermal
    # interface looks like, which is the failure we are hunting. Filtering it
    # would defeat the point.
    if j - core_tool > JUNCTION_DELTA_FLAG:
        flags.append("implausible_delta")

    # Bit-identical for minutes while the die demonstrably moved = a frozen
    # register, not a steady temperature. Absence of this check is why NVML's
    # placeholder constants (8C / 17C) went unnoticed for weeks.
    if hist and hist.get("value") == j and hist.get("since") is not None:
        held = now - hist["since"]
        core_at = hist.get("core_at")
        if (held > JUNCTION_FROZEN_SECS and core_ref is not None
                and core_at is not None
                and abs(core_ref - core_at) > JUNCTION_FROZEN_CORE_MOVE):
            return False, "frozen", flags

    return True, None, flags


def junction_for(bdf):
    """Gated junction reading for one PCI address, maintaining history+latch.

    Returns (sample, valid, reason, flags) - sample is the raw dict so callers
    can still publish the tool's core/vram for auditing even when junction
    itself is rejected.
    """
    with jlock:
        s = dict(jlive[bdf]) if bdf in jlive else None
    with coreref_lock:
        ref = dict(coreref[bdf]) if bdf in coreref else None
    h = jhist.get(bdf)
    valid, reason, flags = junction_gate(s, ref, h)

    if s is not None and s.get("junction") is not None:
        cur = jhist.get(bdf)
        if cur is None or cur.get("value") != s["junction"]:
            jhist[bdf] = {"value": s["junction"], "since": time.time(),
                          "core_at": (ref or {}).get("core")}

    # Two-stage latch: one mismatching tick is usually sampling skew, since a
    # 5090 moves ~10C/s at load onset. Only a sustained disagreement means the
    # mapping itself is wrong - and then no GPU's junction can be trusted.
    if reason == "core_mismatch":
        jtrust["bad"] += 1
        jtrust["good"] = 0
        if jtrust["bad"] >= JUNCTION_MISMATCH_LATCH and jtrust["trusted"]:
            jtrust["trusted"] = 0
            log("junction mapping UNTRUSTED after %d consecutive core "
                "mismatches (bdf=%s tool=%s ref=%s)"
                % (jtrust["bad"], bdf, (s or {}).get("core"),
                   (ref or {}).get("core")))
    elif valid:
        jtrust["good"] += 1
        if jtrust["good"] >= JUNCTION_RETRUST and not jtrust["trusted"]:
            jtrust["trusted"] = 1
            jtrust["bad"] = 0
            log("junction mapping re-trusted after %d clean samples"
                % jtrust["good"])

    if not jtrust["trusted"]:
        return s, False, "map_untrusted", flags
    return s, valid, reason, flags


class Fam:
    """Groups samples by metric family so HELP/TYPE is emitted exactly once,
    immediately before that family's samples.

    Prometheus' text parser tolerates interleaved families and duplicate HELP
    lines; strict OpenMetrics does not, and this file is gaining a lot of
    families. Routing every appended metric through here keeps the exposition
    valid regardless of the order we happen to discover GPUs in.
    """

    def __init__(self):
        self._meta = {}      # name -> (help, type)
        self._samples = {}   # name -> [rendered sample lines]

    def add(self, name, help_text, mtype, labels, value):
        if name not in self._meta:
            self._meta[name] = (help_text, mtype)
            self._samples[name] = []
        if labels:
            lbl = ",".join('%s="%s"' % (k, v) for k, v in labels.items())
            self._samples[name].append("%s{%s} %s" % (name, lbl, value))
        else:
            self._samples[name].append("%s %s" % (name, value))

    def render(self):
        out = []
        for name, (help_text, mtype) in self._meta.items():
            out.append("# HELP %s %s" % (name, help_text))
            out.append("# TYPE %s %s" % (name, mtype))
            out.extend(self._samples[name])
        return out


def _emit_gpu_extras(fam, uuid, bus, ok, hot, mean, seen):
    """The per-GPU block normally emitted alongside a VRAM/HOT_SPOT line."""
    seen.add(uuid)
    base = {"gpu_uuid": uuid, "pci_bus_id": bus}
    fam.add("gddr6_vram_valid",
            "Whether the BAR-level GDDR reading is usable (0 = dead GPU or stale)",
            "gauge", base, 1 if ok else 0)
    with live_lock:
        e = live.get(bus)
    if ok and e:
        fam.add("gddr6_vram_temp_max_celsius",
                "Hottest GDDR module on this GPU, from BAR registers",
                "gauge", base, hot)
        fam.add("gddr6_vram_temp_mean_celsius",
                "Mean GDDR module temperature on this GPU, from BAR registers",
                "gauge", base, mean)
        for i, v in enumerate(e["modules"]):
            fam.add("gddr6_vram_module_temp_celsius",
                    "Per-module GDDR temperature from BAR registers",
                    "gauge", dict(base, module=str(i)), v)
    if JUNCTION_MODE != "off":
        emit_junction(fam, base, bus)


def emit_junction(fam, base, bus):
    """Publish junction plus everything needed to audit whether to believe it.

    Note on labels: the NVML index is deliberately NOT a label on any
    temperature series. If indices ever shifted, an index label would break
    graph continuity on exactly the series being used to diagnose the card.
    The index is published separately, as info.
    """
    s, valid, reason, flags = junction_for(bus)
    st = jstats.get(bus, {})

    fam.add("gpu_junction_reader_up",
            "1 = the per-GPU junction reader process is running",
            "gauge", base, st.get("up", 0))
    fam.add("gpu_junction_reader_restarts_total",
            "Restarts of this GPU's junction reader since service start",
            "counter", base, st.get("restarts", 0))
    fam.add("gpu_junction_parse_errors_total",
            "Unparseable lines from the junction tool (a schema change shows "
            "up here rather than as a wrong temperature)",
            "counter", base, st.get("parse_errors", 0))
    fam.add("gpu_junction_map_trusted",
            "0 = sustained core mismatch, junction suppressed for ALL GPUs",
            "gauge", base, jtrust["trusted"])
    fam.add("gpu_junction_temp_valid",
            "1 = this junction reading passed the validity gate",
            "gauge", base, 1 if valid else 0)
    if reason:
        fam.add("gpu_junction_invalid_reason",
                "Why the current junction reading was rejected (1 = active)",
                "gauge", dict(base, reason=reason), 1)
    for fl in flags:
        fam.add("gpu_junction_flag",
                "Non-fatal anomaly on an otherwise valid reading (a large "
                "junction-core delta is a degrading thermal interface, which "
                "is a finding, not a reason to discard the sample)",
                "gauge", dict(base, flag=fl), 1)

    if s:
        fam.add("gpu_junction_last_sample_timestamp_seconds",
                "Unix time of this GPU's newest junction sample",
                "gauge", base, round(s["ts"], 3))
        if s.get("index") is not None:
            fam.add("gpu_junction_index_info",
                    "NVML index the junction tool reported for this PCI address",
                    "gauge", dict(base, index=str(s["index"])), 1)
        if s.get("core") is not None:
            fam.add("gpu_core_temp_celsius",
                    "GPU core (edge) temperature; source label makes the "
                    "junction cross-check auditable in Prometheus",
                    "gauge", dict(base, source="gputemps"), s["core"])
        if s.get("vram") is not None:
            fam.add("gpu_vram_temp_max_celsius",
                    "Hottest VRAM module as reported by the junction tool - an "
                    "independent second opinion on gddr6_vram_temp_max_celsius",
                    "gauge", dict(base, source="gputemps"), s["vram"])

    with coreref_lock:
        ref = dict(coreref[bus]) if bus in coreref else None
    if ref:
        fam.add("gpu_core_temp_celsius",
                "GPU core (edge) temperature; source label makes the junction "
                "cross-check auditable in Prometheus",
                "gauge", dict(base, source="nvml"), ref["core"])
        if ref.get("tlimit") is not None:
            fam.add("gpu_thermal_margin_celsius",
                    "Official NVIDIA thermal margin (T.Limit). LOWER IS HOTTER "
                    "- alert on <= a small number, never >=. Measured to be "
                    "exactly 90 - core on these cards, so it carries no "
                    "information beyond core temperature.",
                    "gauge", base, ref["tlimit"])

    if valid:
        fam.add("gpu_junction_temp_celsius",
                "GPU junction/hotspot temperature from BAR0 MMIO. Canonical "
                "name - prefer this over DCGM_FI_DEV_HOT_SPOT_TEMP. Vendor "
                "guidance: sustained >=100C under a defined load is a service "
                "case.",
                "gauge", base, s["junction"])
        if s.get("core") is not None:
            fam.add("gpu_junction_core_delta_celsius",
                    "junction - core, computed from one instant so both "
                    "operands share a timestamp. A rising trend at constant "
                    "power is thermal-interface degradation.",
                    "gauge", base, s["junction"] - s["core"])


def merge_once(umap):
    try:
        with open(RAW) as f:
            raw = f.read()
    except OSError:
        return False
    by_uuid = {v: k for k, v in umap.items()}
    out = []
    fam = Fam()
    val_re = re.compile(r'^(DCGM_FI_DEV_(?:VRAM|HOT_SPOT)_TEMP\{[^}]*UUID="([^"]+)"[^}]*\})\s+(\S+)')
    seen = set()
    for line in raw.splitlines():
        m = val_re.match(line)
        if m:
            head, uuid, orig = m.group(1), m.group(2), m.group(3)
            bus = by_uuid.get(uuid)
            hot, mean, ok = value_for(bus) if bus else (None, None, False)
            if "HOT_SPOT" in head and JUNCTION_MODE == "authoritative":
                # P3: the name finally means what it says. Reuse the upstream
                # line's exact label set so dashboards keep working. When the
                # reading is invalid we OMIT the line entirely rather than pass
                # through the 17C placeholder - a gap is honest and alertable
                # via absent(), whereas a fake healthy value would defeat the
                # >=100C alert this whole feature exists to raise.
                _s, jok, _r, _f = junction_for(bus) if bus else (None, False, None, [])
                if bus and uuid not in seen:
                    _emit_gpu_extras(fam, uuid, bus, ok, hot, mean, seen)
                if jok:
                    out.append("%s %s" % (head, _s["junction"]))
                # else: emit NOTHING for this family. Falling back would put
                # either the GDDR maximum or - far worse - the raw 17C NVML
                # placeholder under a name that now means junction, and a fake
                # healthy value silently defeats the >=100C alert this exists
                # to raise. A gap is honest and alertable with absent().
                # The GDDR maximum remains available as
                # gddr6_vram_temp_max_celsius for anything that wants it.
                continue
            elif ok:
                # HOT_SPOT = hottest module; VRAM = mean across modules
                repl = hot if "HOT_SPOT" in head else mean
            else:
                repl = orig
            out.append("%s %s" % (head, repl))
            if bus and uuid not in seen:
                seen.add(uuid)
                base = {"gpu_uuid": uuid, "pci_bus_id": bus}
                fam.add("gddr6_vram_valid",
                        "Whether the BAR-level GDDR reading is usable (0 = dead GPU or stale)",
                        "gauge", base, 1 if ok else 0)
                with live_lock:
                    e = live.get(bus)
                if ok and e:
                    # explicit names for the two aggregates - DCGM_FI_DEV_HOT_SPOT_TEMP
                    # is a GDDR maximum today and that is not what "hot spot" means
                    fam.add("gddr6_vram_temp_max_celsius",
                            "Hottest GDDR module on this GPU, from BAR registers",
                            "gauge", base, hot)
                    fam.add("gddr6_vram_temp_mean_celsius",
                            "Mean GDDR module temperature on this GPU, from BAR registers",
                            "gauge", base, mean)
                    for i, v in enumerate(e["modules"]):
                        lbl = dict(base, module=str(i))
                        fam.add("gddr6_vram_module_temp_celsius",
                                "Per-module GDDR temperature from BAR registers",
                                "gauge", lbl, v)
                if JUNCTION_MODE != "off":
                    emit_junction(fam, base, bus)
        else:
            out.append(line)
    fam.add("gddr6_vram_merge_timestamp_seconds",
            "Unix time of the last successful merge (staleness check)",
            "gauge", None, int(time.time()))
    # makes the RUNNING code observable: install replaces the file but a live
    # interpreter keeps the old bytecode, which is how one host silently ran a
    # stale merger for weeks. Compare this across hosts to detect drift.
    fam.add("vram_metrics_merge_info", "Version and checksum of the running merger",
            "gauge", {"version": VERSION, "file_sha256": _self_sha()}, 1)
    if JUNCTION_MODE != "off":
        fam.add("gpu_junction_tool_info",
                "Pinned build of the junction reader actually running",
                "gauge", dict(TOOL_INFO, mode=JUNCTION_MODE), 1)
    out.extend(fam.render())
    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(out) + "\n")
    os.replace(tmp, OUT)               # atomic: metrics_exporter never sees a partial file
    return True


TOOL_INFO = tool_build_info()


def junction_manager(get_umap):
    """Keep exactly one reader thread alive per known PCI address.

    Started lazily rather than once at boot because a GPU can appear after a
    power cycle, and a card that is dead at start-up should get a reader if it
    ever comes back.
    """
    started = set()
    while True:
        for bdf in sorted(get_umap() or {}):
            if bdf not in started:
                started.add(bdf)
                jstat(bdf)
                threading.Thread(target=junction_reader, args=(bdf,),
                                 daemon=True).start()
                log("junction reader started for %s" % bdf)
        time.sleep(30)


def main():
    os.makedirs(os.path.dirname(RAW), exist_ok=True)
    threading.Thread(target=reader, daemon=True).start()
    umap, last_map = uuid_map(), time.time()
    log("vram-metrics-merge: raw=%s out=%s gpus=%d" % (RAW, OUT, len(umap)))
    if JUNCTION_MODE != "off":
        threading.Thread(target=core_ref_sampler, daemon=True).start()
        threading.Thread(target=junction_manager, args=(lambda: umap,),
                         daemon=True).start()
        log("junction: mode=%s tool=%s build=%s"
            % (JUNCTION_MODE, JUNCTION_TOOL, TOOL_INFO["commit"]))
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
