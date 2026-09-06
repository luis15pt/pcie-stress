# PSU swap record — 2026-09-06

Goal: make each host's PSU shelf a **uniform model** (all WRA or all WRB), after
noticing that G1136-1600W**RA** and **RB** units were mixed in both chassis and
that the odd-model-out was always the unit not reporting DC 12 V output.

## Before the swap (serials per user)

| Host | Slot 0 | Slot 1 | Slot 2 |
|------|--------|--------|--------|
| Juno | 001    | 300    | 394    |
| Zhen | 007    | 396    | 008    |

Serial families visible in metrics (full strings):

- **Family A** — `G11361600A2101000xx` : 001, 007, 008
- **Family B** — `G1136162RA2112002xx` : 246, 299, 300, 394, 395, 396

Before the swap that gives Juno = 1×FamA + 2×FamB, Zhen = 2×FamA + 1×FamB.
NOTE: family != confirmed model. The mapping of serial family to WRA/WRB is a
hypothesis until MFR_MODEL (PMBus 0x9A) is read from each unit.

## After the swap (read from metrics, 2026-09-06 ~21:05 WEST)

| Host | Slot 0            | Slot 1              | Slot 2            |
|------|-------------------|---------------------|-------------------|
| Juno | `...100001q` 0 W  | `...200300-` 148 W  | `...200394` 159 W |
| Zhen | `...100001q` 0 W  | `...200396` 198 W   | `...100008` 0 W   |

## ⚠ Anomalies seen BEFORE the BMC reset (now resolved — see RESULT)

1. **Serial `G11361600A210100001q` appears on BOTH hosts at the same time.**
   Physically impossible — one of the two is a misread.
2. **On both hosts the unit reporting 0 W is the same unit whose serial ends in
   a garbage character** (`q`, and previously `x`, `c`, `-`). The PMBus
   MFR_SERIAL read and the DC output read appear to be failing *together*.

Implication: a "0 W" reading may mean **"the exporter could not talk to this
unit"** rather than "this unit is not sharing". That materially weakens the
earlier conclusion that a specific unit was refusing to load-share, and it must
be resolved before drawing further conclusions.

Independent corroboration from the BMC (brand-agnostic, sees slots 0 and 1 only)
at the same moment:

- Juno: PSU1 POUT = 0 W steady, PSU2 POUT = 147 W steady
- Zhen: PSU1 POUT erratic (294 → 287 → 0 → 49 → 0), PSU2 POUT 273 → 413 W

So Juno slot 0 really is at zero (two independent sources agree), while Zhen
slot 0 is *unstable* rather than cleanly off.

## To confirm the actual models — requires SSH

Per host, for each PSU at PMBus 0xB0 / 0xB2 / 0xB4 on i2c bus 2:

    ipmitool i2c bus=2 0xB0 16 0x9A   # MFR_MODEL  -> expect G1136-1600WRA / ...RB
    ipmitool i2c bus=2 0xB0 16 0x9E   # MFR_SERIAL -> cross-check against above
    ipmitool i2c bus=2 0xB0 2  0x79   # STATUS_WORD

(0xE0 / 0xE4 answer but are NOT PSUs — exclude.)

---

# RESULT — confirmed after BMC cold reset (2026-09-06 ~21:40 WEST)

Read directly from each PSU over PMBus, bypassing the exporter.

## The swap was done CORRECTLY — each shelf is now uniform

| Host | 0xB0 | 0xB2 | 0xB4 |
|------|------|------|------|
| Zhen | G1136-1600W**RA** / 001 | **RA** / 007 | **RA** / 008 |
| Juno | G1136-1600W**RB** / 396 | **RB** / 300 | **RB** / 394 |

(`WRAE` / `WRBL` seen on 0xB4 are a trailing-byte read artifact — asking for 20
bytes of a 19-char string. Same cause as the `q`/`x`/`c`/`-` on serials.)

Exactly one unit was exchanged each way: 001 Juno->Zhen, 396 Zhen->Juno.

**Serial-family -> model mapping, now CONFIRMED (was a hypothesis):**
- `G11361600A2101000xx` = **WRA**
- `G1136162RA2112002xx` = **WRB**

## Both hosts now load share across all three PSUs

Six consecutive samples each, direct PMBus READ_POUT (0x96), linear11 decoded:

| Host | 0xB0 | 0xB2 | 0xB4 | Spread | Total | GPU load |
|------|------|------|------|--------|-------|----------|
| Zhen | ~297 W | ~314 W | ~303 W | 5%  | ~915 W | 622 W |
| Juno | ~96 W  | ~101 W | ~106 W | 10% | ~307 W | 136 W |

Stable across all samples — this is genuine active current-sharing, not
failover. **Mixed WRA/WRB revisions in one shelf were the root cause of the
load-sharing failure.** A mismatched unit sat on the share bus without ever
taking its portion, which is why the odd-model-out never reported DC output.

## What this means operationally

- Capacity is now 3 x 1600 W = **4800 W** with real N+1, against a ~3.07 kW peak
  at full 5-GPU load.
- Losing one PSU now leaves 3200 W vs a 3070 W peak (96%) — survivable, but
  still thin. Previously, losing one left 1600 W vs 3070 W, i.e. guaranteed
  cascade. That was the mechanism behind BOTH 2026-09-06 shutdowns.

## Loose ends (cosmetic / telemetry only, hardware is fine)

1. Exporter serials carry a trailing garbage character — it reads 20 bytes for a
   19-char field. Trim to the declared block length.
2. Juno's PSU exporter takes **~30 s per scrape** (serial PMBus reads); that
   likely exceeds Prometheus' scrape timeout, so Juno's PSU series go missing
   from Grafana intermittently. Zhen's is fine. Worth parallelising the reads or
   caching between scrapes.
3. `octoserver_psu_status_ok` read 1 for a PSU delivering 0 W under a 3 kW load
   throughout both crashes — status alone never detects a load-share failure.
   An alert on per-PSU share imbalance is still needed.

## BMC reset

Both BMCs cold-reset successfully (firmware 3.08, back in ~10 s). Note the
reset briefly makes PMBus reads return zeros/no-reading — readings taken within
~30 s of the reset are not trustworthy, which produced a false "0 W" scare
during this session.
