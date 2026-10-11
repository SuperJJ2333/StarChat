# Media regressions from the shared reliability gate

## Recovery entry

- Authorization: parent dispatched correction of the user's approved IM reliability R7b/R8 plan after candidate 9902d350 full-gate failures; parent additionally authorized scheduler.hasConsumers and the bubble lifecycle fixture. No additional user approval is needed for these reversible source/test fixes.
- Plan: docs/superpowers/plans/2026-10-11-im-reliability-remediation.md. Preserve ADR-0060, account generations, cancellation, byte budgets and source/cache separation.
- Owner: review_media_android; native managed worktree im-media-cache-regression/StarChat, branch codex/im-media-cache-regression. Base 9902d35079e9cb051125808a251ae479b06893cb. Production files: media_cache.dart and only the read-only hasConsumers API in media_load_scheduler.dart. Six scoped test files. A helper edited only audit/transfer-integrity/video fixture assertions under this owner; no concurrent file edits occurred.
- Status: implementation and focused validation complete; frozen source awaits non-author SPEC/domain -> quality/security review and parent integration. Parent retains full project/platform/package acceptance.
- Next executable step: review the frozen commit and docs/verification/artifacts/2026-10-11/im-media-cache-regression/README.md, then integrate into the shared candidate and run parent-owned gates.

## Evidence and decisions

The artifact README maps each reported failure to its demonstrated cause and correction. Baseline five-file run was 20 PASS/14 FAIL; the dedicated priority RED observed 192 MiB reserved before source scheduling. Final impact suite is 87 PASS; separate chain suite is 111 PASS with six overlapping consumer tests; eight-file analysis has zero issues. Failed intermediate lifecycle output is retained, followed by its real-settlement GREEN.

Ruling: adapt count/callback/worker-settlement fixtures to current contracts rather than reverting quota metadata, bounded HTTP callbacks or worker hashing. The replacement assertions check exact transport bytes/URLs and complete managed file sets, and wait for actual results with bounded widget waits. A mistaken classification would permit a security/duplication regression, so original corruption, account isolation, exact-descriptor and source call-count assertions remain or are strengthened.

Ruling: schedule the complete cold source operation before reserving its whole byte peak, and keep its slot until cache settlement. This preserves priority/rejoin while retaining budget lifetime; disk/local admitted paths remain direct. The cost is that a network slot also spans verification/storage, bounded by the existing concurrency cap. No streaming or RSS target is claimed.

## Timing and verification identity

Baseline test start/end UTC: 2026-10-11T06:40:30.2792335Z to 2026-10-11T06:41:03.9044205Z, exit 1. Final command's exact UTC interval is retained in final-impact-run.json and the input identity record. Other log creation/write UTC timestamps bound those runs; no exact active engineering duration is invented. Worktree setup used a native registered checkout and official offline locked dependencies.

No deployment, package, database migration or secrets change. Rollback is the isolated commit reversal. The prior shared full-gate failures remain historically recorded; only the named affected tests and adjacent chains were run here, per parent scope and evidence reuse rules.
