# Media regressions from the shared reliability gate

## Recovery entry

- Authorization: parent dispatched correction of the user's approved IM reliability R7b/R8 plan after candidate 9902d350 full-gate failures; parent additionally authorized scheduler.hasConsumers and the bubble lifecycle fixture. No additional user approval is needed for these reversible source/test fixes.
- Plan: docs/superpowers/plans/2026-10-11-im-reliability-remediation.md. Preserve ADR-0060, account generations, cancellation, byte budgets and source/cache separation.
- Owner: review_media_android; native managed worktree im-media-cache-regression/StarChat, branch codex/im-media-cache-regression. Base 9902d35079e9cb051125808a251ae479b06893cb. Production files: media_cache.dart and only the read-only hasConsumers API in media_load_scheduler.dart. Six scoped test files. A helper edited only audit/transfer-integrity/video fixture assertions under this owner; no concurrent file edits occurred.
- Status: implementation and focused validation complete; frozen source awaits non-author SPEC/domain -> quality/security review and parent integration. Parent retains full project/platform/package acceptance.
- Next executable step: review the frozen commit and docs/verification/artifacts/2026-10-11/im-media-cache-regression/README.md, then integrate into the shared candidate and run parent-owned gates.

## Independent review follow-up

The 44dabcc9 review found a real, pre-existing late-store publication gap: the last observer could leave while store awaited its path provider and still publish afterward. Parent authorized this bounded follow-up in the same isolated tree. It changes only media_cache.dart, adds media_cache_publication_test.dart and records evidence. Scheduler, Matrix, RoomPage, native code and quota implementation are untouched.

The unchanged reviewer probe is reproduced RED (1 PASS / 1 FAIL); new root/flush probes are RED (2 PASS / 3 FAIL). Current private publication guards dynamically check current consumers and captured global/account generations after path preparation, after queued atomic writes and temporary flush, and before index/memory publication. A rename already submitted with live demand is allowed to settle; previously published objects/sidecars are not rolled back. No resource is released early and cancellation does not permanently prevent rejoining the real source.

New gates: 7 publication tests PASS (including two unchanged independent probes), 93 impacted tests PASS in one run, two-file analyze zero issues. Counts overlap and are not added as unique tests. See publication-followup.md and publication-input-identities.json in the existing artifact directory for exact boundaries, inputs and timing. Next step: backend_review independently reviews this follow-up SPEC/domain then quality/security, then parent integrates the accepted SHA. These implementer gates are not independent approval or device/platform acceptance.

## Shared object-demand review correction

Independent review of c3 found a newly introduced cross-source cancellation regression: source B joined A's verified object Future and inherited A's publication guard. New object demand aggregation preserves one write and actual settlement while references keep their individual source checks. An additional same-event/different-source RED demonstrated an earlier whole-store join bypass; removing that redundant join preserves all unique synchronous preparation registrations for playback and account cleanup. See object-join-followup.md and object-join-input-identities.json in the same artifact directory.

New evidence: independent c3 probe 1 PASS / 1 FAIL; actual-object-flush probe 2 PASS / 1 FAIL; intermediate same-reference probe 3 PASS / 1 FAIL. Final 13 boundary cases PASS, impacted 12 files / 97 tests PASS, three-file analyze zero issues. The 97 include prior 93 plus the new four join cases; counts overlap the 13 and are not summed. The new report explicitly corrects the original sidecar-versus-object test barrier description. No df1b3/iOS test dependency; cherry-pick order is 44dab -> c3 -> this follow-up. Parent must still validate the integrated shared SQLCipher factory/full suite/native package candidate. Next executable step: backend_review's independent SPEC/domain -> quality/security review of the frozen follow-up, then accepted integration.

## Evidence and decisions

The artifact README maps each reported failure to its demonstrated cause and correction. Baseline five-file run was 20 PASS/14 FAIL; the dedicated priority RED observed 192 MiB reserved before source scheduling. Final impact suite is 87 PASS; separate chain suite is 111 PASS with six overlapping consumer tests; eight-file analysis has zero issues. Failed intermediate lifecycle output is retained, followed by its real-settlement GREEN.

Ruling: adapt count/callback/worker-settlement fixtures to current contracts rather than reverting quota metadata, bounded HTTP callbacks or worker hashing. The replacement assertions check exact transport bytes/URLs and complete managed file sets, and wait for actual results with bounded widget waits. A mistaken classification would permit a security/duplication regression, so original corruption, account isolation, exact-descriptor and source call-count assertions remain or are strengthened.

Ruling: schedule the complete cold source operation before reserving its whole byte peak, and keep its slot until cache settlement. This preserves priority/rejoin while retaining budget lifetime; disk/local admitted paths remain direct. The cost is that a network slot also spans verification/storage, bounded by the existing concurrency cap. No streaming or RSS target is claimed.

## Timing and verification identity

Baseline test start/end UTC: 2026-10-11T06:40:30.2792335Z to 2026-10-11T06:41:03.9044205Z, exit 1. Final command's exact UTC interval is retained in final-impact-run.json and the input identity record. Other log creation/write UTC timestamps bound those runs; no exact active engineering duration is invented. Worktree setup used a native registered checkout and official offline locked dependencies.

No deployment, package, database migration or secrets change. Rollback is the isolated commit reversal. The prior shared full-gate failures remain historically recorded; only the named affected tests and adjacent chains were run here, per parent scope and evidence reuse rules.
