#!/usr/bin/env python3
"""nvtop/glances-style live dashboard for the containerized C-Payne suite.

Top: per-GPU telemetry (util/mem/temp/power via nvidia-smi) merged with each
GPU's PCIe link state and AER counters (root port + endpoint), with deltas
since the monitor started. Below: non-GPU devices with AER errors, the
gpu_burn log, and kernel AER/Xid events.
Usage: aer_watch.py [interval_seconds]
"""
import signal
import subprocess
import sys
import time
from pathlib import Path

from rich.console import Console, Group
from rich.layout import Layout
from rich.live import Live
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

PCI = Path("/sys/bus/pci/devices")
BURN_LOG = Path("/tmp/gpu_burn.log")
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


def smi() -> dict[str, dict]:
    """{bdf: {util, mem_used, mem_total, temp, power, plimit}} via nvidia-smi."""
    q = "pci.bus_id,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit"
    try:
        out = subprocess.run(
            ["nvidia-smi", f"--query-gpu={q}", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10).stdout
    except OSError:
        return {}
    info = {}
    for line in out.splitlines():
        f = [x.strip() for x in line.split(",")]
        if len(f) != 7:
            continue
        bdf = f[0].lower().replace("00000000:", "0000:")
        num = lambda s: float(s) if s.replace(".", "").isdigit() else 0.0
        info[bdf] = dict(util=num(f[1]), mem_used=num(f[2]), mem_total=num(f[3]),
                         temp=num(f[4]), power=num(f[5]), plimit=num(f[6]))
    return info


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


def gpu_table(base: dict) -> Table:
    tel = smi()
    tbl = Table(expand=True, header_style="bold cyan", border_style="dim")
    for col in ("GPU", "util", "mem", "temp", "power", "link", "width",
                "AER cor port(+run)", "AER cor dev(+run)", "nf/fatal"):
        tbl.add_column(col)
    for dev, port in gpus():
        t = tel.get(dev.name, {})
        cs, ms = read(dev / "current_link_speed").split(" ")[0], read(dev / "max_link_speed").split(" ")[0]
        cw, mw = read(dev / "current_link_width"), read(dev / "max_link_width")
        degraded = read(port / "current_link_speed") != read(port / "max_link_speed")
        mem = f"{t.get('mem_used', 0):.0f}/{t.get('mem_total', 0):.0f}M" if t else "-"
        pw = f"{t.get('power', 0):.0f}/{t.get('plimit', 0):.0f}W" if t else "-"
        nf_p, nf_d = aer(port, "nonfatal", "TOTAL_ERR_NONFATAL"), aer(dev, "nonfatal", "TOTAL_ERR_NONFATAL")
        ft_p, ft_d = aer(port, "fatal", "TOTAL_ERR_FATAL"), aer(dev, "fatal", "TOTAL_ERR_FATAL")
        bad = any(x for x in (nf_p, nf_d, ft_p, ft_d))
        tbl.add_row(
            f"{dev.name}\n[dim]port {port.name}[/]",
            bar(t.get("util", 0.0)) if t else Text("-", style="dim"),
            mem,
            temp_cell(t["temp"]) if t else Text("-", style="dim"),
            pw,
            Text(f"{cs}/{ms} GT/s", style="bold red" if degraded else ""),
            f"x{cw}/x{mw}",
            count_cell(cor(port), base, port.name),
            count_cell(cor(dev), base, dev.name),
            Text(f"{nf_p}/{nf_d} {ft_p}/{ft_d}", style="bold red" if bad else "green"),
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


def render(base: dict) -> Layout:
    up = float(Path("/proc/uptime").read_text().split()[0])
    head = Text.assemble(
        ("  C-Payne PCIe/GPU stress monitor  ", "bold reverse"),
        (f"  {time.strftime('%H:%M:%S')}  host up {int(up // 3600)}h{int(up % 3600 // 60):02d}m", "dim"))
    lay = Layout()
    lay.split_column(
        Layout(head, size=1),
        Layout(Panel(gpu_table(base), title="GPUs + PCIe links", border_style="cyan"), name="gpus", ratio=3),
        Layout(name="mid", ratio=2),
        Layout(Panel(Text(tail_lines(["dmesg"], match=("AER:", "Xid")), style="dim"),
                     title="kernel AER/Xid log", border_style="red"), name="klog", ratio=2),
    )
    lay["mid"].split_row(
        Layout(others_panel(base)),
        Layout(Panel(Text(tail_lines(BURN_LOG, n=6), style="dim"),
                     title="gpu_burn log", border_style="magenta")),
    )
    return lay


def summary(base: dict) -> None:
    end = snapshot()
    tbl = Table(title="AER correctable — this run", expand=False)
    for col in ("device", "start", "end", "delta this run"):
        tbl.add_column(col)
    clean = True
    for bdf in sorted(end):
        s, e = base.get(bdf, 0), end[bdf]
        if e == 0 and s == 0:
            continue
        clean = False
        d = e - s
        tbl.add_row(f"{bdf}  {lspci_name(bdf)[:40]}", str(s), str(e),
                    Text(f"+{d}", style="bold red" if d else "green"))
    if clean:
        console.print("[bold green]All AER counters zero — clean run.[/]")
    else:
        console.print(tbl)


def log_mode(base: dict, interval: float, stop: list) -> None:
    """No TTY (docker logs, redirects): print compact status lines instead."""
    interval = max(interval, 10.0)
    while not stop:
        tel = smi()
        parts = []
        for dev, port in gpus():
            t = tel.get(dev.name, {})
            d = (cor(port) or 0) - base.get(port.name, 0) + (cor(dev) or 0) - base.get(dev.name, 0)
            parts.append(f"{dev.name[5:]} {t.get('util', 0):3.0f}%% {t.get('temp', 0):.0f}C "
                         f"{t.get('power', 0):.0f}W aer+{d}")
        noisy = [f"{d.name}+{c - base.get(d.name, 0)}"
                 for d in (sorted(PCI.iterdir()) if PCI.is_dir() else [])
                 if (c := cor(d)) and c - base.get(d.name, 0) > 0]
        line = time.strftime("%H:%M:%S ") + " | ".join(parts)
        if noisy:
            line += "  !! deltas: " + " ".join(noisy)
        print(line.replace("%%", "%"), flush=True)
        time.sleep(interval)


def main() -> None:
    interval = float(sys.argv[1]) if len(sys.argv) > 1 else 3.0
    base = snapshot()
    if not base:
        console.print("[bold red]No AER counters in /sys — need --privileged and OS-native AER (BIOS).[/]")
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    try:
        if console.is_terminal:
            with Live(render(base), console=console, screen=True, refresh_per_second=4) as live:
                while not stop:
                    time.sleep(interval)
                    live.update(render(base))
        else:
            log_mode(base, interval, stop)
    except KeyboardInterrupt:
        pass
    summary(base)


if __name__ == "__main__":
    main()
