# Emoji recent-order correction and cold-entry investigation

## Recovery / authorization

User reports on installed Android0.4.55+2224: recent emojis reorder during input; a cold-list click takes2–3s; asks why full identity preflight costs2.21–2.68s and whether snapshots can bypass it. User explicitly specifies freezing recents while expanded and refreshing next expansion. Existing approved startup cache-first design remains the target; no approval to remove identity/E2EE safeguards or publish production.

Root owns emoji panel and its tests, this task/plan/report and new diagnostics under docs/verification/artifacts/2026-10-18/emoji-cold-entry. Existing clean worktree interactive-cache-startup, baseline10f56377. No CodeGraph. Installed normal2224 APK0b25c384…af33b3a, fixed75b31 signer; keep account data. Cold-entry investigation initially read-only; product changes require reproduced cause and tests. Prior startup/send task is complete, retained as baseline rather than reopened.

## Acceptance

| ID | Requirement | Status |
| --- | --- | --- |
| EC1 | Stable visible recent emoji order and grid coordinates during one expansion; usage persists; next expansion reflects latest order; account isolation | investigating; immediate setState reordering confirmed |
| EC2 | Real installed cold-launch entry measurement; distinguish cache HIT/MISS and per-stage waiting | pending |
| EC3 | Explain minimal cache identity checks versus full SDK DB preflight and its measured cost; retain safety boundaries | source trace underway |

Initial source findings: _selectStatic immediately updates _recents; factory cache admission returns seeded rooms before full preflight, and cached openRoomLease bypasses lifecycle serialization. Full preflight copies/hash-checks encrypted DB/WAL/SHM, checks snapshot and final originals, then reads identity records. No conclusion yet about this reported room delay.

Next executable step: record installed normal cold launches without sending; add failing emoji position/frozen-list regressions, then minimal correction under linked plan. Exact commands/times/exit codes in artifact receipts. No production changes.

## 2026-10-18 15:19+08 freeze checkpoint

EC1 RED actual recent coordinates swapped after a click; smallest correction freezes visible recents but preserves serialized record, and rejects late initial load after selection. Final affected5files39PASS (emoji-final-green), analyzer0/17.4s; held-load test registers teardown before assertions to release gate/unmount/drain/reset mock. Final SPEC then independent QUALITY/security PASS. Reuse unchanged startup/E2EE/native and unaffected shared coverage from2224. source-gate-binding.json binds exact final Dart hashes. Original2224 full/errors remain documented; no all-green full command claim. Missing.env blocks aggregate verify, no secret import.

Reserve normal Debug0.4.56+2225 after both workspace workflow/pubspec searches found no competing reservation. Product changes only emoji panel and version; startup/auth/SDK/navigation/storage/native code unchanged. Fixed signer/install-r/data preservation required. Frozen direct worktree checked against all tracked mobile Git blobs before/after compilation, no concurrent shared-input tests/builds and no all-input reproducibility claim. No production update/download changes.

EC2 user clarified ALL rooms including 测试群. Installed2224 read-only intrinsic conversation samples330/409/449/529/532ms, all cacheHIT. Metric starts inside business callback, so cannot exclude input delivery/presentation delay. r1/r4 overlap host tests and are not controlled performance comparisons. r5 ran after tests ended: early tap on firstProjectionContentFrame log, screenshots00 black/01 list/02 cached room+bubbles+composer. Screen02 acquisition starts hosttap+1359ms, finishes+1906ms; interval is not an exact presentation timestamp. Neither callback449ms nor this image proves or disproves the user's2–3s. Cause remains unresolved. Cached lease path does bypass complete identity/SDK readiness; no security relaxation made.

EC3 prior controlled2224 preflight2212/2490/2682ms. Per-file max observations: copy+hash750.850–878.968ms, snapshot hash461.356–574.992ms, final source recheck450.443–842.125ms; SQL identity read115.769–163.586ms, fingerprint7.075–12.091ms. These are file samples, not sums/total percentiles. Full check verifies account/device/Olm/DB before SDK writes, distinct from small authenticated account/key binding for cache display. Async future is not a separate Dart CPU isolate; SHA still executes in caller isolate. This is source evidence, not proof of input-delay causality.

Next: freeze mobile source, conventional rebuild/fixed sign/verify, install normal2225 with UID/firstInstall/hash guards, verify emoji positions without sending and preserve original draft. Final report/index must keep cold-entry root cause OPEN, not call it fixed by emoji-only delivery.


## Final emoji delivery / cold-entry remains OPEN — 2026-10-18T15:42:44.364790+08:00

- EC1 delivered: normal0.4.56+2225, source84152b0f205dc8b44506a6dbdf1881dbc9913734, APK SHAe992a25726f3849c9f0662632caadeb9df2b14df016ac91bd3206311815e9ba8, 126114138B, fixed75b31 signer. Main-build-2225-r2 all source/rebuild/sign/alignment/semantic gatesPASS, exact raw-source manifest before/after matches2141Git blobs. Initial buildNPE and diagnostic argument failure preserved, final complete build reverified, no diagnostic artifact delivery. Existing KGP migration warning verified in2224 original source-build log; no new dependency change.
- Final install-r PASS, actual installed APK SHA matches, UID10090 and firstInstall2026-09-26 04:06:20 retained. Native ordinary UI emoji-device PASS: same physical second-recent target twice yields same emoji, close/reopen promotes it to first; no send clicks, initial empty draft restored. Evidence screenshots and booleans under emoji-device. No screenshots of nonempty original draft are taken by this test.
- Final affected39PASS and analyzer0; final SPEC→QUALITY/securityPASS, no code changes after source freeze except build-generated untracked outputs. Broader unchanged modules reuse2224 evidence; no all-green full command claim. Aggregate verify lacks.env, no production credentials imported.
- EC2 repair remains OPEN; concrete slow path reproduced in final clean2225 run: cacheAdmissionMiss/admissionRejected, SDK6064ms ready before click, lease11ms→routepush1446ms (1435ms local timeline prepare/scheduling), content1817ms. Totaltrace4886ms includes later remote sync and is not first-content duration. Identity preflight already ended at3870ms, so it did not cause this post-SDK pre-push wait. Exact admission rejection cause and all-room common causality not yet determined; earlier callback traces still omit native input/presentation. No startup/auth/SDK/navigation product change. EC3 explanation complete: minimal display admission is separate, full preflight need not block cache display.

Next executable work: fix cache-miss page preparation gating under an approved bounded design, separate route visibility from local timeline readiness; retain account/key/privacy validation and authenticated-cache fallback. Add closed admission rejection and pre-push preparation substage timings, correlate native input→Dart→presentation. Do not remove safety checks or reuse callback330–532ms as end-to-end proof. Debug installed now; no active builder/driver/mapping/forward remains. This task made no production settings or download changes. See [verification report](../../verification/2026-10-18-emoji-stable-recents-cold-entry.md).
