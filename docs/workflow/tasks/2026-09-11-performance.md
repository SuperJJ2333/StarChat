# Performance implementation and production delivery

## Recovery
- User authorization: execute all five phases and publish after tests; Android currently published baseline, include iOS; stable cross-device encrypted media hash confirmed.
- Plan: ../../superpowers/plans/2026-09-11-performance-execution.md
- Status: baseline and implementation setup; no production writes or new artifacts published.
- Worktree: D:/pythonProject/outsource/StarChat/.worktrees/performance-20260911, codex/performance-20260911; merges 7bc73ec3 and 0f65614d. Dirty main changes excluded.
- Owner: parent integration/docs/baselines/delivery; subtask owners assigned explicitly.
- Start: 2026-09-11T01:15+08:00 approximate, exact first tool timestamp unavailable.
- Next: verify published versions, prepare Flutter dependency environment, reproduce avatar failure/publication dependencies.

## Acceptance ledger
| ID | Expected | Implementation | Tests | Production |
| --- | --- | --- | --- | --- |
| PERF00 | Baseline and reproducible load/fault cases | pending | pending | N/A |
| PERF01 | Avatar retry/independent profile publication | pending | pending | pending |
| PERF02 | Offline timeline independent of optional network operations | pending | pending | pending |
| PERF03 | Draft and composer decoupling | pending | pending | pending |
| PERF04 | Incremental bounded timeline with identity/ordering correctness | pending | pending | pending |
| PERF05 | Shared cache budget and media priority scheduling | pending | pending | pending |
| PERF06 | Offline persisted moments pagination | pending | pending | pending |
| PERF07 | Conversation/profile/viewer completion | pending | pending | pending |
| PERF08 | Android/iOS functional and performance validation | pending | pending | pending |
| PERF09 | Verified production publication, per-platform artifact evidence | pending | pending | pending |

## Timing and evidence
- Setup: isolated worktree created and latest iOS binding changes merged without conflict; 2026-09-11T01:17+08:00 observed.
- Tool path: C:/src/flutter/bin/flutter.bat; adb E:/software/platform-tools/adb.exe. flutter/dart/gh not on process PATH.
- No tests/performance/production completion claimed.

## Baseline evidence (2026-09-11T01:22+08:00)
- Live read-only Setting rows: Android 0.3.80/2084 (min 3), iOS 0.3.81/2085 (min 0). Android URL /download?install=1; iOS /download?platform=ios&install=1. Log: docs/verification/artifacts/2026-09-11/performance/production-settings-baseline.log, exit0. No update settings changed.
- Live Android symlink targets ChatFlow-0.3.80-build2084-arm64.apk; iOS manifest2085 targets enterprise-762fb649. API container image observed fea5b9417e5c; re-read digest before any write.
- adb devices -l returned no connected devices. Physical frame/input verification not yet possible on this host; continue implementation and platform build preparation.
- Combined source baseline 3b75a64ec51aaac49098975b6b90dca21d6bbde1. Flutter3.44.9, Dart3.12.2. pub get succeeds with existing locks; no upgrade requested.
- Timeline/draft baseline command from apps/mobile_flutter: C:/src/flutter/bin/flutter.bat test test/performance/room_timeline_baseline_test.dart test/features/matrix/room_timeline_controller_test.dart test/features/matrix/room_draft_store_test.dart --reporter expanded. Exit0,13passed. Synthetic unchanged-refresh100 samples: 300messages p95=265us, 50000messages p95=12195us; both emitted100notifications. Desktop/JIT controller timings only, shared-host variability; no mobile frame claim. Log timeline-baseline.log.
- Metrics TDD: performance_metrics_test.dart first failed missing implementation exit1; implemented typed bounded recorder and startup observation,3 tests pass exit0; focused analyze3items passed exit0. Logs metrics-red.log/metrics-green.log. Review pending; these probes do not complete all PERF00 mobile scenarios.
- Signing preflight: established Android diagnostic.p12 exists; contents/password not read. iOS existing channel historically requires returned enterprise signature; no new signing artifact is assumed present.
- PERF00 scoped spec review found capacity assert-only guard and misleading membership fixture label. Both fixed, regression witnessed red exit1 then six tests green exit0. Actual senderPoolSize=1000; distinctSenders300/1000; membership workload=false. Full group membership/frame scenarios remain pending. Re-run p95 varied to18713us at50000 (shared host), no improvement claim.
- Scoped spec re-review PASS and quality/security APPROVED at 2026-09-11T01:29+08:00 (approximate). Metrics preserves pipeline total latency vs real dropped-frame distinction. VM service method ext.chatflow.performance returns aggregate stats, reset=true optionally clears after reading; enabled in profile or explicit CHATFLOW_PERFORMANCE_METRICS diagnostic build. No network upload/persistence.
