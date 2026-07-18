#!/usr/bin/env python3
"""nvtop/glances-style monitor for the containerized C-Payne suite.

TTY: live Rich dashboard (GPU telemetry + PCIe link/AER state).
No TTY (docker logs): heartbeat line per GPU every 2s plus EVENT lines on
state changes (throttle transitions, clock drops, AER increments, GPU
disappearing from nvidia-smi). Both end with per-run summary tables:
AER deltas and a GPU health verdict (thermal / errors / dropout).
Usage: aer_watch.py [interval_seconds]
"""
import signal
import subprocess
import sys
import time
from collections import deque
from pathlib import Path

from rich.console import Console, Group
from rich.layout import Layout
from rich.live import Live
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

PCI = Path("/sys/bus/pci/devices")
BURN_LOG = Path("/tmp/gpu_burn.log")
HW_FLAGS = {"HW-SLOWDOWN", "HW-THERMAL", "HW-POWER-BRAKE"}
THROTTLE_BITS = (  # nvml clocks-event/throttle-reason bitmask
    (0x8, "HW-SLOWDOWN"), (0x40, "HW-THERMAL"), (0x80, "HW-POWER-BRAKE"),
    (0x20, "sw-thermal"), (0x4, "sw-power-cap"),
    (0x2, "app-clocks"), (0x100, "display-clocks"), (0x10, "sync-boost"),
)
_reason_field = ["clocks_event_reasons.active"]  # falls back to deprecated name
console = Console()


def read(p: Path) -> str:
    try:
        return p.read_text().strip()
    except OSError:
        return "?"


def aer(dev: Path, which: str, key: str) -> int | None:
    try:
        for line in (dev / f"aer_dev_{which}").read_text().splitlines():
            k, _, v = line.partition(" ")
            if k == key:
                return int(v)
    except (OSError, ValueError):
        pass
    return None


def cor(dev: Path) -> int | None:
    return aer(dev, "correctable", "TOTAL_ERR_COR")


def gpus() -> list[tuple[Path, Path]]:
    out = []
    for dev in sorted(PCI.iterdir()) if PCI.is_dir() else []:
        if not dev.name.endswith(".0"):
            continue
        if read(dev / "vendor") != "0x10de" or not read(dev / "class").startswith("0x03"):
            continue
        out.append((dev, PCI / dev.resolve().parent.name))
    return out


def snapshot() -> dict[str, int]:
    if not PCI.is_dir():
        return {}
    return {d.name: c for d in PCI.iterdir() if (c := cor(d)) is not None}


def throttle_flags(mask: int) -> set[str]:
    return {name for bit, name in THROTTLE_BITS if mask & bit}


def fmt_flags(flags: set[str]) -> str:
    return ",".join(sorted(flags)) if flags else "-"


def smi() -> dict[str, dict]:
    """{bdf: {util, mem_*, temp, power, plimit, clk, clk_max, reasons}}."""
    base_q = ("pci.bus_id,utilization.gpu,memory.used,memory.total,"
              "temperature.gpu,temperature.memory,fan.speed,"
              "power.draw,power.limit,clocks.sm,clocks.max.sm,clocks.mem")
    out = ""
    for _ in range(2):
        q = f"{base_q},{_reason_field[0]}"
        try:
            r = subprocess.run(
                ["nvidia-smi", f"--query-gpu={q}", "--format=csv,noheader,nounits"],
                capture_output=True, text=True, timeout=10)
        except OSError:
            return {}
        out = r.stdout
        if r.returncode == 0 and out.strip():
            break
        _reason_field[0] = "clocks_throttle_reasons.active"  # older drivers
    info = {}
    for line in out.splitlines():
        f = [x.strip() for x in line.split(",")]
        if len(f) != 13:
            continue
        bdf = f[0].lower().replace("00000000:", "0000:")
        num = lambda s: float(s) if s.replace(".", "").isdigit() else 0.0
        opt = lambda s: float(s) if s.replace(".", "").isdigit() else None  # N/A -> None
        try:
            mask = int(f[12], 16)
        except ValueError:
            mask = 0
        info[bdf] = dict(util=num(f[1]), mem_used=num(f[2]), mem_total=num(f[3]),
                         temp=num(f[4]), vram=opt(f[5]), fan=opt(f[6]),
                         power=num(f[7]), plimit=num(f[8]),
                         clk=num(f[9]), clk_max=num(f[10]), mclk=num(f[11]), reasons=mask)
    return info


class Tracker:
    """Accumulates per-GPU health stats and emits EVENT strings on changes."""

    def __init__(self, base: dict[str, int]):
        self.base = base
        self.prev_aer = dict(base)
        self.prev_tel: dict[str, dict] = {}
        self.tel: dict[str, dict] = {}
        self.stats: dict[str, dict] = {}
        self.gone: set[str] = set()
        self.events: deque[str] = deque(maxlen=200)
        self.seen_klog: set[str] = set()
        self.klog_primed = False

    def kernel_events(self) -> list[str]:
        """New AER/Xid kernel lines since last tick (needs dmesg access)."""
        try:
            out = subprocess.run(["dmesg"], capture_output=True, text=True, timeout=5).stdout
        except OSError:
            return []
        lines = [l for l in out.splitlines() if "AER:" in l or "Xid" in l]
        fresh = [l for l in lines if l not in self.seen_klog]
        self.seen_klog.update(fresh)
        if not self.klog_primed:      # first tick: don't replay pre-run history
            self.klog_primed = True
            return []
        return [f"{time.strftime('%H:%M:%S')} EVENT [kernel] {l.strip()}" for l in fresh[-10:]]

    def gpu_run_delta(self, dev: Path, port: Path) -> int:
        cur = snapshot()
        return sum(cur.get(b.name, 0) - self.base.get(b.name, 0) for b in (dev, port))

    def tick(self, interval: float) -> list[str]:
        ts = time.strftime("%H:%M:%S")
        events: list[str] = []
        tel = smi()
        for bdf in self.prev_tel:
            if bdf not in tel and bdf not in self.gone:
                self.gone.add(bdf)
                events.append(f"{ts} EVENT gpu={bdf} DISAPPEARED from nvidia-smi (fallen off the bus?)")
        for bdf, t in tel.items():
            if bdf in self.gone:
                self.gone.discard(bdf)
                events.append(f"{ts} EVENT gpu={bdf} reappeared in nvidia-smi")
            s = self.stats.setdefault(bdf, dict(
                max_temp=0.0, max_vram=None, max_fan=None, min_clk=None, max_clk=0.0,
                hw_s=0.0, swt_s=0.0, run_s=0.0))
            s["max_temp"] = max(s["max_temp"], t["temp"])
            if t["vram"] is not None:
                s["max_vram"] = t["vram"] if s["max_vram"] is None else max(s["max_vram"], t["vram"])
            if t["fan"] is not None:
                s["max_fan"] = t["fan"] if s["max_fan"] is None else max(s["max_fan"], t["fan"])
            s["max_clk"] = max(s["max_clk"], t["clk"])
            if t["util"] > 50:  # only count clocks under load
                s["min_clk"] = t["clk"] if s["min_clk"] is None else min(s["min_clk"], t["clk"])
            flags = throttle_flags(t["reasons"])
            if flags & HW_FLAGS:
                s["hw_s"] += interval
            if "sw-thermal" in flags:
                s["swt_s"] += interval
            s["run_s"] += interval
            prev = self.prev_tel.get(bdf)
            if prev:
                pf = throttle_flags(prev["reasons"])
                if (flags - {"sw-power-cap"}) != (pf - {"sw-power-cap"}):
                    events.append(f"{ts} EVENT gpu={bdf} throttle changed: {fmt_flags(pf)} -> {fmt_flags(flags)}")
                if prev["clk"] > 0 and t["clk"] < prev["clk"] * 0.85:
                    events.append(f"{ts} EVENT gpu={bdf} sm clock dropped {prev['clk']:.0f} -> {t['clk']:.0f} MHz")
        cur = snapshot()
        for bdf, c in cur.items():
            p = self.prev_aer.get(bdf, 0)
            if c > p:
                events.append(f"{ts} EVENT dev={bdf} AER correctable +{c - p} "
                              f"(run total +{c - self.base.get(bdf, 0)})")
        self.prev_aer = cur
        self.prev_tel = tel
        self.tel = tel
        events += self.kernel_events()
        self.events.extend(events)
        return events


def bar(pct: float, width: int = 14) -> Text:
    pct = max(0.0, min(100.0, pct))
    filled = round(pct / 100 * width)
    style = "green" if pct < 60 else "yellow" if pct < 85 else "red"
    return Text("█" * filled + "░" * (width - filled) + f" {pct:3.0f}%", style=style)


def temp_cell(t: float) -> Text:
    return Text(f"{t:.0f}°C", style="green" if t < 70 else "yellow" if t < 86 else "bold red")


def count_cell(now: int | None, base: dict, bdf: str) -> Text:
    if now is None:
        return Text("?", style="dim")
    delta = now - base.get(bdf, 0)
    if delta > 0:
        return Text(f"{now} (+{delta})", style="bold red")
    if now > 0:
        return Text(f"{now} (+0)", style="yellow")
    return Text("0", style="green")


def lspci_name(bdf: str) -> str:
    try:
        out = subprocess.run(["lspci", "-s", bdf], capture_output=True, text=True, timeout=5).stdout
        return out.partition(" ")[2].strip()
    except OSError:
        return ""


def tail_lines(cmd_or_path, match=None, n=8) -> str:
    try:
        if isinstance(cmd_or_path, Path):
            lines = cmd_or_path.read_text(errors="replace").splitlines() if cmd_or_path.exists() else []
        else:
            out = subprocess.run(cmd_or_path, capture_output=True, text=True, timeout=5).stdout
            lines = out.splitlines()
        if match:
            lines = [l for l in lines if any(m in l for m in match)]
        return "\n".join(l[-160:] for l in lines[-n:]) or "(nothing yet)"
    except OSError:
        return "(unavailable — need --privileged?)"


def gpu_table(base: dict, trk: Tracker) -> Table:
    tel = trk.tel or smi()
    tbl = Table(expand=True, header_style="bold cyan", border_style="dim")
    for col in ("GPU", "util", "temp", "vram/fan", "power", "sm clk", "throttle",
                "link", "AER cor port(+run)", "AER cor dev(+run)"):
        tbl.add_column(col)
    for dev, port in gpus():
        t = tel.get(dev.name, {})
        cs, ms = read(dev / "current_link_speed").split(" ")[0], read(dev / "max_link_speed").split(" ")[0]
        cw = read(dev / "current_link_width")
        degraded = read(port / "current_link_speed") != read(port / "max_link_speed")
        flags = throttle_flags(int(t.get("reasons", 0)))
        thr_style = "bold red" if flags & HW_FLAGS else "yellow" if "sw-thermal" in flags else "dim"
        gone = dev.name in trk.gone
        tbl.add_row(
            Text(f"{dev.name}\nport {port.name}", style="bold red" if gone else ""),
            Text("DROPPED?", style="bold red") if gone else (bar(t.get("util", 0.0)) if t else Text("-", style="dim")),
            temp_cell(t["temp"]) if t else Text("-", style="dim"),
            (f"{t['vram']:.0f}°C" if t.get("vram") is not None else "n/a")
            + " / " + (f"{t['fan']:.0f}%" if t.get("fan") is not None else "n/a") if t else "-",
            f"{t.get('power', 0):.0f}/{t.get('plimit', 0):.0f}W" if t else "-",
            f"{t.get('clk', 0):.0f}/{t.get('clk_max', 0):.0f}" if t else "-",
            Text(fmt_flags(flags - {"sw-power-cap"}), style=thr_style),
            Text(f"{cs}/{ms} GT/s x{cw}", style="bold red" if degraded else ""),
            count_cell(cor(port), base, port.name),
            count_cell(cor(dev), base, dev.name),
        )
    return tbl


def others_panel(base: dict) -> Panel:
    gpu_bdfs = {p.name for pair in gpus() for p in pair}
    tbl = Table(expand=True, show_header=False, box=None)
    noisy = False
    for dev in sorted(PCI.iterdir()) if PCI.is_dir() else []:
        c = cor(dev)
        if not c or dev.name in gpu_bdfs:
            continue
        noisy = True
        tbl.add_row(Text(dev.name, style="red"), count_cell(c, base, dev.name),
                    Text(lspci_name(dev.name)[:48], style="dim"))
    if not noisy:
        tbl.add_row(Text("(none)", style="green dim"))
    return Panel(tbl, title="non-GPU AER errors", border_style="yellow")


def render(base: dict, trk: Tracker) -> Layout:
    up = float(Path("/proc/uptime").read_text().split()[0])
    head = Text.assemble(
        ("  C-Payne PCIe/GPU stress monitor  ", "bold reverse"),
        (f"  {time.strftime('%H:%M:%S')}  host up {int(up // 3600)}h{int(up % 3600 // 60):02d}m", "dim"))
    ev = "\n".join(list(trk.events)[-4:]) or "(no events)"
    klog = tail_lines(["dmesg"], match=("AER:", "Xid"), n=4)
    lay = Layout()
    lay.split_column(
        Layout(head, size=1),
        Layout(Panel(gpu_table(base, trk), title="GPUs + PCIe links", border_style="cyan"), ratio=3),
        Layout(name="mid", ratio=2),
        Layout(Panel(Text(f"{ev}\n[kernel] {klog}", style="dim"),
                     title="events / kernel AER+Xid", border_style="red"), ratio=2),
    )
    lay["mid"].split_row(
        Layout(others_panel(base)),
        Layout(Panel(Text(tail_lines(BURN_LOG, n=6), style="dim"),
                     title="gpu_burn log", border_style="magenta")),
    )
    return lay


def log_mode(base: dict, interval: float, stop: list, trk: Tracker) -> None:
    interval = max(interval, 2.0)
    while not stop:
        events = trk.tick(interval)
        ts = time.strftime("%H:%M:%S")
        for dev, port in gpus():
            t = trk.tel.get(dev.name)
            if not t:
                continue
            d = trk.gpu_run_delta(dev, port)
            flags = throttle_flags(int(t["reasons"]))
            vram = f"vram={t['vram']:.0f}C " if t["vram"] is not None else ""
            fan = f"fan={t['fan']:.0f}% " if t["fan"] is not None else ""
            link = f"{read(dev / 'current_link_speed').split(' ')[0]}GT/s x{read(dev / 'current_link_width')}"
            print(f"{ts} gpu={dev.name[5:]} util={t['util']:.0f}% temp={t['temp']:.0f}C {vram}{fan}"
                  f"pwr={t['power']:.0f}/{t['plimit']:.0f}W sm={t['clk']:.0f}/{t['clk_max']:.0f}MHz "
                  f"mem={t['mclk']:.0f}MHz link={link} aer=+{d} thr={fmt_flags(flags)}", flush=True)
        for e in events:
            print(e, flush=True)
        time.sleep(interval)


def summary(base: dict, trk: Tracker) -> None:
    end = snapshot()
    aer_tbl = Table(title="AER correctable — this run", expand=False)
    for col in ("device", "start", "end", "delta this run"):
        aer_tbl.add_column(col)
    dirty = False
    for bdf in sorted(end):
        s, e = base.get(bdf, 0), end[bdf]
        if e == 0 and s == 0:
            continue
        dirty = True
        d = e - s
        aer_tbl.add_row(f"{bdf}  {lspci_name(bdf)[:40]}", str(s), str(e),
                        Text(f"+{d}", style="bold red" if d else "green"))
    if dirty:
        console.print(aer_tbl)
    else:
        console.print("[bold green]All AER counters zero — clean run.[/]")

    if not trk.stats:
        return
    hp = Table(title="GPU health — this run", expand=False)
    for col in ("GPU", "max temp", "max vram", "max fan", "sm clk min/max",
                "HW throttle", "sw-thermal", "AER Δ", "verdict"):
        hp.add_column(col)
    issues = []
    for dev, port in gpus():
        s = trk.stats.get(dev.name)
        if not s:
            continue
        d = trk.gpu_run_delta(dev, port)
        verdicts = []
        if dev.name in trk.gone:
            verdicts.append(("DROPPED OFF BUS", "bold red"))
        if s["hw_s"] > 0:
            verdicts.append((f"HW THROTTLED {s['hw_s']:.0f}s", "bold red"))
        if s["swt_s"] > 0:
            verdicts.append((f"thermal-throttled {s['swt_s']:.0f}s", "yellow"))
        if d > 0:
            verdicts.append((f"PCIe errors +{d}", "bold red"))
        if s["max_temp"] >= 88:
            verdicts.append((f"hot ({s['max_temp']:.0f}°C)", "yellow"))
        if s["max_vram"] is not None and s["max_vram"] >= 90:
            verdicts.append((f"vram hot ({s['max_vram']:.0f}°C)", "yellow"))
        if not verdicts:
            verdicts = [("OK", "green")]
        else:
            issues.append(f"{dev.name[5:]}: " + ", ".join(v for v, _ in verdicts))
        vt = Text()
        for i, (v, st) in enumerate(verdicts):
            vt.append(("  " if i else "") + v, style=st)
        mn = s["min_clk"] if s["min_clk"] is not None else 0
        hp.add_row(dev.name, temp_cell(s["max_temp"]),
                   f"{s['max_vram']:.0f}°C" if s["max_vram"] is not None else "n/a",
                   f"{s['max_fan']:.0f}%" if s["max_fan"] is not None else "n/a",
                   f"{mn:.0f}/{s['max_clk']:.0f} MHz",
                   f"{s['hw_s']:.0f}s", f"{s['swt_s']:.0f}s", f"+{d}", vt)
    console.print(hp)
    if issues:
        console.print("[bold red]Issues:[/] " + "; ".join(issues))
    else:
        console.print("[bold green]Verdict: no thermal events, no GPU PCIe errors, no dropouts.[/]")
    for e in list(trk.events):
        if "EVENT" in e:
            console.print(Text(e, style="dim"))


def main() -> None:
    interval = float(sys.argv[1]) if len(sys.argv) > 1 else 2.0
    base = snapshot()
    if not base:
        console.print("[bold red]No AER counters in /sys — need --privileged and OS-native AER (BIOS).[/]")
    trk = Tracker(base)
    stop: list = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    try:
        if console.is_terminal:
            with Live(render(base, trk), console=console, screen=True, refresh_per_second=4) as live:
                while not stop:
                    time.sleep(interval)
                    trk.tick(interval)
                    live.update(render(base, trk))
        else:
            log_mode(base, interval, stop, trk)
    except KeyboardInterrupt:
        pass
    summary(base, trk)


if __name__ == "__main__":
    main()
