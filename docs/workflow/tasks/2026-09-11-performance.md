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

## PERF01 first candidate and review
- Commit ecc3da9da129940f06896d056458e8cf5ad6f6ad: independent publication, serialized disk writes, resolver credential handling, stable URL digest, first retry implementation. Final tests avatar-final-green.log71pass exit0; final analyzer avatar-analyze-final.log7items/noissues exit0. Earlier avatar-analyze.log is retained failed lint evidence, not final result.
- Specification review REQUEST CHANGES: initial retry budget exhausts after long outage; actual HTTP/decode failures happen below URL resolver and are not retried. Not accepted as completed PERF01.
- Approved corrective design: shared foreground avatar retry scheduler, backoff1/2/5/15/30 seconds then60-second cap, max4due jobs/second; cancel stale/disposed/deleted/offscreen owners, no concurrent attempt peridentity. Real image retry must re-resolve stream with SAME resource key/URL; no URL cache busting. Covers plain HTTP avatars and Matrix ones without adding network plugin or changing domain APIs. Recovery latency at cap is up to60seconds plus bounded queue delay, not instantaneous connectivity detection.
- Additional scope owned by avatar implementer: ui/components/user_avatar.dart, ui/foundation/avatar_retry.dart, corresponding tests. Matrix SDK/API files remain untouched in this correction.
- Python3.12 pytest/sqlalchemy/alembic preflight passes. Docker daemon unavailable, but docker compose --env-file .env.example config --quiet passes exit0; daemon issue is not a compose-render blocker. Local runtime DB gates will use available verified environment/CI as applicable. No fullverify result claimed.
- PERF00/PERF02 exact widget reproduction at2026-09-11T01:34+08:00: new room_offline_loading_test.dart creates local SDK timeline, then setReadMarker throws synthetic SocketException. Expected cached text remains; actual full-page Chinese load error found. flutter test --no-pub test/features/matrix/room_offline_loading_test.dart --reporter expanded exits1 as intended (offline-red.log). Fixture uncommitted awaiting subsequent PERF02 implementation; avatar owner must not stage it. This is no longer only a static suspected error path.
- PERF00 draft microbenchmark: test/performance/draft_snapshot_baseline_test.dart (100/10000 Chinese-character bases,1000 edits each, real RoomDraftStore.save, deferred flush latest-value assertion),2pass exit0. draft-baseline.log p95=26us/44us, p99=80us/96us respectively. Desktop synchronous snapshot only, excludes IME/render/disk; this evidence does NOT prove draft serialization is dominant jank cause. Prioritize overlapping timeline/rebuild work in PERF03/04, retain typed snapshot optimization for allocation reduction.
- PERF01 correction commit6fd2234111bf54000b8c0835c62dba067d750529: actual byte-layer recovery and shared bounded-rate scheduler. avatar-review-regression-final.log77pass exit0; avatar-review-analyze-final.log12items/noissues exit0. Real loopbackHTTP503 and invalidimagecodec cases paint afterretry, unchanged URL/key; two subscribers share retry download.
- Spec rereview confirms initial2gapsclosed, requests one lifecycle correction: becoming hidden/background during asynchronous cache eviction must defer newImage reconstruction untilactive. Avatar implementer currently owns corrective followup; spec reviewer /root/avatar_spec_review will rereview, then fresh quality reviewer. Full PERF01 not yet accepted. No parent command/CI/build/deployment running; subagent status must be revalidated on resume.
- Parent-owned unstaged fixtures: room_offline_loading_test.dart (intended red), performance/draft_snapshot_baseline_test.dart (2pass), taskrecord. Do not accidentally stage these into avatar correction commit. Subsequent task PERF02 starts from the proven offline failure once PERF01 passes bothreviews.
- PERF05 root-cause evidence: MediaMemoryCache.get synchronously recomputes sha256 for every content-key hit, despite byte identity reuse. New PERF00 fixture performance/media_hit_baseline_test.dart uses2MiB syntheticbytes,51logicalevents/3rooms sharingcontenthash,50warm samples; loaderCalls1,retainedBytes2097152,p50=12875us,p95=13718us,p99=14555us. media-hit-baseline.log1pass exit0. This proves CPU cost without duplicate download/codec/disk, not actualGIF frames. Prioritize immutable owned verified bytes + O(1) warmread in PERF05; don't merely delete validation on externally mutablebytes.
- Avatar second quality lifecycle issue corrected4fd3f42a264c089a552766c9ac4f393253d9ff66: successful pending Matrix resolution usesrunAfter beforeURLpublication; red-final1failure,21focusedtests pass,2fileanalyze clean. Awaitspec confirmation thenqualityclose. All other phaseimplementation/delivery stillpending.

## PERF01 accepted / PERF02 and PERF05a underway
- PERF01 independent spec PASS and quality APPROVED at4fd3f42a264c089a552766c9ac4f393253d9ff66. Lifecycle after byte cleanup and URL resolution both guarded; phone acceptance remains pending.
- PERF02 delegated to offline_room_impl; exclusive ownership room_page.dart and offline/readreceipt helper/tests. Parent owns media_cache.dart, its tests, baselines and this record. No production mutation.
- PERF05a red: media-immutable-red.log contains2 intended failed assertions: producer mutation changes returned bytes; wrong hash accepted on insertion. Process wrapper printed tail and returned0, Flutter log itself reports2failures; do not misrepresent wrapper status as successful tests.
- PERF05a candidate: copy into owned unmodifiable Uint8List, validate hash before store once, return same immutable result to initial/coalesced/warm consumers; get now O(1). Future.sync catches synchronous loader failure; clear generation prevents old flight from repopulating/removing a newer flight.
- Existing content media fixtures had stale send permission mocks and shared global memory between tests. Baseline source run reproduces these failures (media-existing-regression-baseline.log); corrected mocks/isolated caches. Disk corruption tests explicitly clear valid RAM first so they exercise disk verification. Existing E2EE and corruption assertions preserved.
- media-immutable-verified-green.log35pass exit0, same desktop2MiB warm benchmark p95=22us vs13718us baseline, loader1/2MiB retained. CPU cache path only, not phone/GIF decoder/frame acceptance. Added seed replacement, synchronous failure and clear/new-flight regressions afterward; final result recorded media-immutable-final-green.log. Scoped4file analyze-final clean; earlier analyze unused benchmark import was fixed and original failedlog retained. Specification review underway, quality review next; do not claim fullPERF05 completed.
- Next executable work: complete media spec then quality review/commit; offline agent finish tests/reviews; proceed typed draft/composer and incremental timeline. Unified cache budget/scheduler/moments/views and Android/iOS build/device/release gates remain required.
- PERF05a final expanded scope includes RoomImagePreviewCache readCached returning owned bytes. Quality review caught first/warm decoder identity regression; media-preview-identity-red.log1fail, fixed and expanded8file49tests pass(media-preview-final-green.log),9file scoped analyze clean(media-draft-analyze-final.log). Spec rereviewPASS and qualityAPPROVED. Benchmarklastp9517us, no physical claim. Fullbudget/scheduler remains pending.
- PERF02 commit783caf1a containsroompage/offlinefixture;62regressionspass andanalyzeclean. Independent specPASS, qualityinprogress. Timeline implementation now delegated (controller/adapter/tests only), parent owns draft/composer/UIintegration/docs.
- PERF03a draft snapshot red1failure: nested mention recipients could be mutated through returnedcache. Typed immutable snapshot implemented preservingvalidrange checks, JSONonly atflush;8tests pass (draft-immutable-green.log),10000charp9511us versus44usbaseline desktop. Fullcomposer/IME/framegoal notyetcomplete; spec/quality pending.
