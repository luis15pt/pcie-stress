#!/usr/bin/env python3
"""Table test for junction_gate() - runs anywhere, needs no GPU.

This predicate is the entire safety argument for publishing a third-party BAR
register read as a "this card needs service" signal, so it is tested
exhaustively and offline. Run: python3 host/test_junction_gate.py
"""
import importlib.util
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "merge", os.path.join(HERE, "vram-metrics-merge.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

NOW = 1_000_000.0
fails = []


def check(label, sample, ref, hist, want_valid, want_reason=None,
          want_flags=()):
    valid, reason, flags = m.junction_gate(sample, ref, hist, now=NOW)
    ok = (valid == want_valid
          and (want_reason is None or reason == want_reason)
          and set(want_flags) <= set(flags))
    if not ok:
        fails.append("%-38s got valid=%s reason=%s flags=%s | want valid=%s "
                     "reason=%s flags=%s"
                     % (label, valid, reason, flags, want_valid, want_reason,
                        list(want_flags)))
    return ok


def s(junction, core=80, ts=NOW, vram=90, index=0):
    return {"junction": junction, "core": core, "vram": vram, "index": index,
            "ts": ts}


def r(core=80):
    return {"core": core, "tlimit": 90 - core, "ts": NOW}


# --- the value sweep the plan calls for ------------------------------------
# junction vs a fixed core of 80: below, equal, plausible, alarm band, ceiling
CORE = 80
sweep = [
    (None, False, "junction_null"),
    (0,    False, "junction_zero"),
    (45,   False, "below_core"),     # far below core = wrong profile/offset
    (79,   True,  None),             # -1 tolerance absorbs truncation
    (80,   True,  None),
    (95,   True,  None),
    (100,  True,  None),             # the vendor's service threshold: MUST pass
    (105,  True,  None),
    (110,  True,  None),             # must NOT be discarded by a 115 ceiling
    (115,  True,  None),
    (120,  True,  None),
    (125,  True,  None),             # ceiling is inclusive
    (126,  False, "impossible"),
]
for j, want, reason in sweep:
    check("sweep j=%s" % j, s(j, core=CORE), r(CORE), None, want, reason)

# a large delta is a FINDING, not a discard: it is what a failing thermal
# interface looks like, so it must stay valid and merely raise a flag
check("delta>40 stays valid", s(126 - 1, core=60), r(60), None, True, None,
      ("implausible_delta",))
check("delta<=40 unflagged", s(95, core=60), r(60), None, True, None)
if "implausible_delta" in m.junction_gate(s(95, core=60), r(60), None,
                                          now=NOW)[2]:
    fails.append("delta of exactly 35 should not be flagged")

# --- staleness -------------------------------------------------------------
check("fresh", s(100, ts=NOW - 1), r(), None, True)
check("stale >15s", s(100, ts=NOW - 16), r(), None, False, "stale")
check("no sample at all", None, r(), None, False, "no_sample")

# --- attribution -----------------------------------------------------------
check("tool core missing", s(100, core=None), r(), None, False, "no_core")
check("core within tol", s(100, core=80), r(82), None, True)
check("core mismatch >3", s(100, core=80), r(90), None, False, "core_mismatch")
# no reference available must NOT invalidate - it only removes the cross-check
check("no core reference", s(100, core=80), None, None, True)

# --- frozen register -------------------------------------------------------
# held long enough AND the die demonstrably moved => frozen
check("frozen: held 400s, core moved 20",
      s(100, core=80), r(80),
      {"value": 100, "since": NOW - 400, "core_at": 60},
      False, "frozen")
# same hold, but the die did not move => a genuinely steady temperature
check("steady: held 400s, core moved 2",
      s(100, core=80), r(80),
      {"value": 100, "since": NOW - 400, "core_at": 78},
      True)
# moved a lot but only held briefly => not yet frozen
check("held 60s only",
      s(100, core=80), r(80),
      {"value": 100, "since": NOW - 60, "core_at": 60},
      True)
# the real-world case this guards: a constant placeholder while load ramps
check("placeholder 17C during ramp",
      s(17, core=17), r(85),
      {"value": 17, "since": NOW - 3600, "core_at": 30},
      False, "core_mismatch")   # caught even earlier, by attribution

# --- ordering: earlier rules win ------------------------------------------
check("stale beats junction_null", s(None, ts=NOW - 99), r(), None, False,
      "stale")
check("no_core beats junction_zero", s(0, core=None), r(), None, False,
      "no_core")

print("junction_gate: %d checks" % (len(sweep) + 16))
if fails:
    print("\nFAILURES (%d):" % len(fails))
    for f in fails:
        print("  " + f)
    sys.exit(1)
print("all pass")
