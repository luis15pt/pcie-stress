# Incident record — September 2026

Detail behind the summaries in Claude's memory files. Three distinct events, two
root causes found, one still open.

---

## 2026-09-04 11:41:49 UTC — Zhen `0000:01:00.0` (GPU-85e2eb9e) Xid 79

**First GPU death with junction telemetry, and the first time a thermal signal
identified a failing card in advance.**

A crit thermal webhook fired at **11:39:03 UTC — 2 m 46 s before the death** —
naming that exact card at 104 °C junction. Incident bundle captured at 11:41:49.

Two cards were loaded. The evidence is card-specific, not load-related:

| Card | Power | Junction max | Median | Core | Delta | Outcome |
|---|---|---|---|---|---|---|
| `01:00.0` | 481–537 W | **108 °C** | 101 | 90 | **18** | **died** |
| `02:00.0` | 571–574 W | 93 °C | 91 | 83 | 10 | survived |

The dying card ran ~15 °C hotter junction while drawing **40–90 W less power**.
Heat was not leaving that die.

Host power ramped 73 W → 1162 W in ~4 minutes and it died at the top of the
ramp, so the power-transient correlation also holds. One event cannot separate
cause from correlate.

Throttling was `SwPowerCap` only — **HW-THERMAL never asserted**, so the
historical "HW-THERMAL at 77–82 °C" anomaly did not recur here.

**UNRESOLVED: failed GPU fan vs failed thermal interface.** A dead fan explains
108 °C at lower power far more simply than degraded paste, and the two have
different remedies. Nothing recorded fan speed at the time:
- the recorder's DCGM field list omitted it
- `nvidia-smi -q -d TEMPERATURE,POWER,PERFORMANCE` has no FAN section
- by the time the bundle ran `nvidia-smi`, the card was off the bus

Fixed afterwards (DCGM field 191 + an explicit `--query-gpu=fan.speed` capture),
so the next event self-answers. **This card still needs a physical fan check.**

Also flagged: `0000:81:00.0` hit 102 °C junction on 2026-09-03 19:52 UTC and had
the worst 6 h-max junction–core delta on the host (21 °C). Still alive. A 6 h max
is sensitive to one skewed sample, so treat as a flag, not proof.

---

## 2026-09-06 — Two total host shutdowns on Zhen (PSU cascade)

| Event | Local (+01:00) | Total draw | Detail |
|---|---|---|---|
| 1 | ~06:07 | **3070 W** | PSU2 tripped 06:04; PSU1 briefly took 1556 W; then it dropped too |
| 2 | ~20:58 | **1875 W** | died at 59% of 2-PSU capacity — "overload" does not explain this |

Symptoms both times: PSUs amber, power button inert, recovery required a **full
AC discharge** (an OCP/OPP trip latches until the input caps drain).

### Root cause: mixed WRA/WRB revisions in one shelf

Mixing `G1136-1600W`**RA** and **RB** in a shared-current-bus shelf breaks load
sharing. The odd-revision unit sits on the share bus reporting `status_ok=1`
while delivering **0 W**, engaging only as failover.

With 2 of 3 actually sharing, **any single trip while total load exceeds 1600 W
is an instant total shutdown** — the survivor is immediately over its own rating.
That covers both events despite their very different loads.

Input also sagged 230 V → **200 V** across event 1.

Fixed by making each shelf uniform (Zhen 3× WRA, Juno 3× WRB). Both then shared
within 5–10%. **A unit long suspected of being faulty was not** — 007 on Zhen had
"never worked" and ran perfectly once among matched siblings.

### Zhen is still N+0 at peak

3 × 1600 W = 4800 W installed; losing one leaves 3200 W.

| Host | 30 d peak | Survives one PSU failure? |
|---|---|---|
| Juno | 2573 W | Yes — 80% loaded |
| Zhen | **3576 W** | **No** — 112% of 2-PSU capacity |

Practical ceiling is nearer **~3050 W** because sharing runs 5–10% uneven (the
hottest unit hits 1600 W before the average does), and the 1600 W rating assumes
healthy input — these feeds sit at 212–222 V and sagged to 200 V.

**Fix: populate the empty 4th backplane slot.** Interim: `nvidia-smi -pl 450`
(~2950 W peak). Avoid 500 W — lands at ~3200 W with zero margin.

---

## Tooling defects found and fixed

| Defect | Impact | Fix |
|---|---|---|
| Recorder used a global `ARMED` latch cleared by the first dead GPU, re-armable only when the dead list was *empty* | **Both hosts were deaf to further dropouts** — Juno for weeks, Zhen since 09-04. Zero re-arm events ever logged. Reported healthy throughout | Per-GPU set-diff arming (`detect_new_dead`) |
| `psu_exporter` unit shipped `CPUQuota=10%` | Scrape 30 s → past Prometheus' timeout → **PSU series silently vanished from Grafana**, exactly the data needed for the shutdowns above. Only bit the BUSY host; idle Zhen did the same work in 4 s | 50%, baked into the unit |
| PMBus block-read length byte read then ignored | Serials gained trailing garbage (`...396x`, `...001q`); **one PSU's serial appeared on two hosts at once** and misdirected a live investigation | Honour the length byte |
| Static identity registers re-read every scrape, incl. a duplicate `0x9A` | ~6 wasted i2c round-trips per PSU per scrape | Cache per address (only on success) |
| Unit named `psu-monitor` on Juno, `psu-exporter` on Zhen | Restarting the wrong name leaves stale code running — happened during deployment | Standardised on `psu-monitor`, unit in repo |
| `vram_loop` ran its own `gddr6` and logged unfiltered | Juno's dead GPU logged a constant 120 °C into `vram.csv`, corrupting post-incident thermal analysis | Read the merged `/metrics.txt` |

### Wrong turns worth remembering

Three plausible theories for the 30 s scrape were all disproved by measurement:
an SDR walk in the temperature fallback (never executes — PMBus temp is
non-zero), an fd leak in the 8.5-day-old process (7 fds), and BMC i2c contention
(a standalone loop ran the identical 60 calls in 5 s while the throttled service
took 30 s). The answer was a systemd resource limit.

Also: an early reading of "Zhen has no CPUQuota" was an artifact of querying a
unit name that does not exist on that host — systemd returns defaults rather than
an error. Both hosts had the same 10% quota.

---

## Still open

1. **Populate Zhen's 4th PSU slot** (or cap to 450 W) — it cannot survive a PSU
   failure at full load.
2. **Per-PSU load-share imbalance alert** — `status_ok` read `1` for a PSU
   delivering 0 W through both shutdowns. Status can never detect this.
3. **Physically check GPU 85e2eb9e's fan.**
4. Deploy `host/prometheus-junction-rules.yml` on 192.168.8.250.
5. RMA GPU `349f61c8`; Crucial P3 drives; Juno's full SEL; Zhen's 8th DIMM.
