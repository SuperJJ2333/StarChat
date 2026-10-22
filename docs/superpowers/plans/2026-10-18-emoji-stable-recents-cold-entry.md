# Stable emoji recents and cold-entry diagnostics

User-approved behavior: recent emojis update between panel expansions, preserving current targets while typing. This is a bounded correction of existing behavior; root executes inline. Read-only diagnosis of cold-entry/preflight extends the already approved cache-first requirements. Do not remove protected checks without a separately reviewed design.

- [x] EC1 RED: click older recent emoji repeatedly and a catalog emoji; assert original positions/order and no new recent row until reopen. GREEN: persist selections without changing visible snapshot; account switch clears snapshot; delayed initial loading cannot apply post-click changes.
- [x] EC2: cold-start installed2224 main, tap existing test group as soon as available, record intrinsic conversation trace and closed startup phases; no message send. Compare HIT/MISS and route/lease/timeline spans before any proposed correction.
- [x] EC3: extract actual per-stage identity samples without adding percentile maxima or confusing DB checking with remote login. Explain cache-display safety versus SDK write/send readiness.
- [x] Focused tests/analyze, specification then quality review, update task/index/report. If a runtime change is delivered, follow source freeze and fixed-signature rebuild workflow; no production release.


Delivery scope: emoji fix and read-only diagnostic findings complete; cold-entry root cause remains OPEN in task ledger. Checked EC2 means the specified measurement was performed, not that latency was fixed.
