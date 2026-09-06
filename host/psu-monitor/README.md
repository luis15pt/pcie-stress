# PSU exporter (`psu_exporter.py`)

Reads all PSUs over PMBus via `ipmitool i2c bus=2` and exports Prometheus
metrics on :9101. **This is the only source that sees all three PSUs** — the
BMC exposes just two of them (slot 2 is invisible to IPMI), which is why it is
load-bearing for the PSU investigation.

Previously it existed only as two diverging copies on two hosts, with no version
control. This is the unified version, deployed to both.

## Deploy

    scp host/psu-monitor/psu_exporter.py <host>:/tmp/
    ssh <host> 'sudo cp /tmp/psu_exporter.py /opt/psu-monitor/ && sudo systemctl restart <unit>'

**The unit name differs per host** — `psu-monitor.service` on Juno,
`psu-exporter.service` on Zhen. Restarting the wrong name silently leaves the
old code running in memory.

## Fixes applied 2026-09-06

1. **CPUQuota** (the big one, config not code): 10% -> 50%. Scrape 30s -> ~4s.
   At 30s it exceeded Prometheus' scrape timeout and the series vanished.
2. **Identity caching**: model/serial/firmware/mfr-id/date were re-read on every
   scrape — 6 i2c round-trips per PSU, one of which read 0x9A twice for two
   fields holding the same value. Now read once per address and cached, but only
   when the read succeeds, so a transient failure cannot pin "unknown".
   `~4s -> ~3s`.
   The CONFIG register (0x1A) is deliberately NOT cached — it carries the
   standby/active mode flag, which genuinely changes and is central to
   diagnosing load sharing.
3. **PMBus block length byte honoured**: it was read and then ignored, so bytes
   past the end of the string leaked in whenever the trailing byte was
   printable, producing serials like `...396x` / `...300-` / `...001q`. Not
   cosmetic — it made one PSU's serial appear on two hosts at once and sent a
   live investigation down the wrong path.
4. **Address discovery** (earlier): probes 0xB0-0xCE and keeps whatever answers,
   rather than assuming a fixed base, so a PSU swap cannot silently blind it.
   Stops before 0xE0/0xE4 — those answer but are not PSUs.

## Known-good behaviour

A healthy shelf shows all three slots carrying comparable load. As of
2026-09-06, with each host on a uniform PSU revision:

- Zhen (3x G1136-1600W**RA**, serials 001/007/008)
- Juno (3x G1136-1600W**RB**, serials 396/300/394)

**Mixing WRA and WRB in one shelf breaks load sharing** — the odd unit sits on
the share bus reporting `status_ok=1` while delivering 0 W. That caused two
total shutdowns on Zhen on 2026-09-06.
