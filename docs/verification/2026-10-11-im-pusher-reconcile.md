# R5 pusher reconciliation and iOS sound policy

Approved plan: integration worktree docs/superpowers/plans/2026-10-11-im-reliability-remediation.md, R5. Parent relayed user authorization to implement; no deployment by this worker. Baseline5c83a08a09b985146bc507a1608cb2153d361e48. Managed worktree im-pusher-reconcile/StarChat, branch codex/im-pusher-reconcile.

Owned: matrix_pusher_service.dart, push_status_registry.dart, app_home.dart, notification_coordinator.dart, notification_diagnostics_page.dart and corresponding tests; separate infra sound fixture. No pubspec/native changes. Parent coordinates shared Flutter/analyze and independent reviews; R4 owns native/plugin files. Artifacts under docs/verification/artifacts/2026-10-11/im-pusher-reconcile only.

## Decisions and progress

- Pre-flight: service and coordinator share preference convergence; app wiring owns lifecycle/network triggers. Reconciliation must preserve generation and shared token binding owner. Static sound identity follows persisted preference only, not a suspended-app DND timer.
- Ruling: use SDK getPushers and verify desired registration data; keep last-write success separate from remote verification. An unavailable/null remote response is unknown, never an empty list proving absence. Successful write still needs readback before verified health.
- Ruling: remote refresh on resume/reconnect plus at most5-minute active-runtime check. Retry uses existing bounded exponential delays without resetting on repeated resume; unavailability does not claim health. OS-suspended execution is not guaranteed, so resume always reconciles.
- Ruling: retain repository evidence location instead of skill-default scratch directory; do not delete release/test evidence on completion.
- Setup: native worktree created and branch established. Flutter3.44.9/Dart3.12.2 located at C:/src/flutter. Initial default mirror offline resolution changed lock artifacts; restored exact HEAD bytes and reran PUB_HOSTED_URL=https://pub.dev pub get --offline --enforce-lockfile successfully. No dependency upgrade is intended.

## Stage timing

Initial exact start unknown. Observed setup checkpoint2026-10-11T10:53:15+08. Baseline and first remote-deletion RED currently running; exact command outputs will be recorded before implementation. Active/tool time split unknown.

## Acceptance and remaining work

Remote deletion same token,20 concurrent resume coalescing, stale5-minute verification, failure/429 unknown and backoff, owner/logout races; static iOS sound-off/on final APNs fixture; persistent-preference convergence/failure diagnostics. DND send-time design and gateway fixture are separate and pending owner coordination. No real vendor push or device claim.

## R5a static candidate

Implemented SDK getPushers readback and same-token remote repair,5-minute active verification, resume/reconnect convergence, shared generation/owner fencing,10-second read timeout, capped5-minute retry delay and Matrix retry_after_ms. Server-requested throttling may exceed5minutes and is honored with remote state unknown.20 concurrent resume calls share admission; stale reads cannot publish new-owner health. Periodic callbacks are cancelled on logout/dispose; OS suspension is not treated as guaranteed execution.

iOS registration identity includes static sound preference. Sound-off omits aps.sound while preserving generic alert; on restores default. Coordinator persists preference, updates snapshot, then converges registration; persistence failure never sends the new remote policy. Diagnostic UI separates past write, last remote check and unknown/pending state. AppHome reuses connection transitions rather than polling on builds. Other push/VoIP payloads remain unchanged.

| Gate | Actual evidence/result |
| --- | --- |
| Baseline before source |23 passed, baseline.txt |
| Remote deletion RED |1 intended failure: remote remains empty, remote-red.txt |
| Initial remote GREEN |23 passed, remote-green.txt |
| Boundary RED |4 passed/3 intended failures: old-owner health, stalled read,10-minute retry exceeds budget; remote-boundary-red-isolated.txt. Earlier non-isolated RED was cancelled after a leaked fake binding made the following test time out; fixed test token isolation, not counted as passing. |
| Sound RED |7 passed/1 intended failure: sound still present; sound-red.txt |
| Persistence/diagnostic RED |27 passed/2 intended failures; preference-diagnostics-red.txt |
|429 RED |1 intended failure: read retried before server30s window; throttle-red.txt |
| Focused final regression |120 passed, static-regression.txt; `flutter test --no-pub test/features/push test/core/notification/notification_coordinator_test.dart test/core/notification/ios_silent_presenter_test.dart test/core/notification/notification_policy_engine_test.dart` |
| Scoped analyze |No issues, static-focused-analyze.txt; includes AppHome and all changed production logic. Initial curly-brace info corrected. |
| Real Sygnal |2 cases PASS, static-sygnal-native.txt. Image matrixdotorg/sygnal:v0.15.1 digest0e3ab79e04371964916f428a99b7fab19f23cbb16089112c4e7d8874c8f301ba. Actual dispatch→truncation→APNs NotificationRequest from actual Dart-generated pusher JSON; only APNs transport is a double, network disabled. |

All complete gates above exited0 except explicitly labelled RED. Tests use synthetic tokens/push metadata; no real push or production credential. Windows10.0.19045, Flutter3.44.9/Dart3.12.2; lock remains baseline after exact restoration. Full Flutter/analyze and final independent SPEC→QUALITY reviews are parent integration gates, intentionally not duplicated. scripts/verify.ps1 was preflighted: no local .env, and init_matrix.ps1 requires it; do not import production secrets. Repository/deployment policy are run independently.

Observed checkpoints:2026-10-11T10:53:15+08 setup; baseline output10:53:57; first RED10:54:11; initial GREEN10:56:15; boundary RED11:00:30; sound RED11:01:36; callback RED11:02:44; focused GREEN11:04:39; broadened120 GREEN11:07:48. Durations are test-log observations; active/tool split remains unknown.

DND next: separate design frozen with root/gateway owner at [wire design](artifacts/2026-10-11/im-pusher-reconcile/dnd-wire-design.md). Root explicitly assigned minimal AppDelegate.swift IANA read method to this worker after R4 froze. New DND code will be a separate commit; gateway implementation belongs to review_media_android. Neither static-only source nor tests claim scheduled DND/real iPhone acceptance.

Rollback: static change is mobile-code-only, no backend schema; restore prior client/service behavior. No APK/IPA built or distributed by this worker. Source candidate is not a deployed or device-accepted result.

## Review correction — preference changes during HTTP 429

Independent review reproduced that preference synchronization entered `ensureRegistered` directly and bypassed the server's `retry_after_ms` deadline. A separate hard server deadline now gates all registration entry points and dirty convergence passes; ordinary offline retry backoff remains separate. The scheduled retry samples the latest preference at expiry. No data is sent during the hard deadline.

2026-10-11 11:21–11:23 +08: test-first `throttle-preferences-red.txt` fails with writes > 1 during the 30-second server window. `throttle-preferences-green.txt` passes 28 focused tests, including 20 preference/direct registration triggers, no reads/writes through second 29, and exactly one write applying the latest silent preference at second 30. `throttle-focused-analyze.txt` reports no issues. This correction is a separate commit after R5a; uncommitted R5b DND changes were saved and excluded.

## R5b — ordinary iOS send-time DND registration

Client changes are a separate candidate from R5a/static sound and the 429 review correction. The frozen wire adds `data.chatflow_ios_policy` with exact fields v=1, revision=1..9007199254740991, IANA timezone, dnd_enabled, start/end minute integers. The revision is persisted before registration, stable across unchanged preference/owner replacement, and increased on window/timezone changes. A new IosPushPolicy uses the existing chatflow/apns channel's read-only getTimeZoneIdentifier method, implemented by TimeZone.current.identifier in AppDelegate.swift. No Android/VoIP path or package/dependency changes.

Registration identity includes the policy and static sound. Missing/invalid native timezone yields explicit invalid metadata and omission of aps.sound, with pending/unknown diagnostics and retry; it never invents an abbreviation/offset. Reserved localtime/posixrules/posix/right identifiers are rejected to agree with the server. Storage failure does not return unpersisted metadata. Generation/owner checks prevent late preparation from writing after disposal; preparation is bounded to 10 seconds (native channel 5 seconds). A late shared-preference write may still finish locally, but cannot issue a pusher write through the expired registration operation. Corrupt/exhausted revisions fail as unknown and do not silently reset identity.

Server implementation is independently owned by im-ios-push-policy, commit de7953ad2916cdb4a4ff8fe1ffd3df7af453a45a. It evaluates [start,end) on actual send UTC converted through ZoneInfo, including retries; wraps midnight, disables equal endpoints, fails closed on invalid policy, and only removes sound from a deep copy. The server does not infer an attention bypass from encrypted event-id-only metadata. Settings copy is platform-scoped to iOS to explain that ordinary background notifications remain silent during DND, attention exceptions are app-local, and updates require successful synchronization. New client package/native acceptance is still required; deployed server support alone does not make currently installed clients publish this field.

2026-10-11 local 11:10–11:36 implementation/evidence: dnd-client-red.txt (5 intended missing-policy failures) → dnd-client-green.txt (5 PASS); dnd-registration-red.txt (9 PASS/2 expected missing wire/failclosed failures) → dnd-registration-green.txt (17 PASS incl throttle); dnd-reserved-zone-red.txt (6 PASS/1 failure) and dnd-policy-timeout-red.txt (1 expected stalled-operation failure) → dnd-regression.txt (133 PASS). The first expanded run had a test orchestration deadlock: it awaited dispose before releasing the deliberately held preparation; dnd-test-ordering-failure.txt preserves the timeout, and the test was corrected to initiate dispose, release, then await. It was not treated as a product RED. Latest fixture-specific run dnd-final-fixture.txt has 21 PASS. Final scoped analyzer has no issues (dnd-focused-analyze.txt); one curly-brace style diagnostic was fixed before the clean rerun.

flutter-dnd-payload.json is emitted by the actual IosPushPolicy default SharedPreferences adapter and MatrixPusherService, with SharedPreferences platform storage and native timezone provider doubled. tests/infra/ios_dnd_sygnal_native.py sends this JSON through the exact reviewed Sygnal candidate sha256:01d1196db73d56449fa2a1c6c62f846ddfb14ceca9c6408fe38f8b835bbc0141, real Notification/payload/truncation/NotificationRequest construction. dnd-sygnal-native.txt passes 5 boundary cases (before start/start/end, static-off, unavailable timezone); only UTC and final APNs transport are replaced, docker network disabled. Alert/unread preserved and policy metadata not leaked into APNs payload. No real device token, certificate or production config is mounted.

Windows cannot compile/run the native iOS extension here. The Dart MethodChannel fixture verifies method name and response handling, while Swift has only the two-line read-only dispatch addition; Xcode/native/device validation remains a release gate. Timezone follows the last successful client registration (foreground, preference changes or active periodic reconciliation); travel during complete suspension/offline cannot update the already registered zone. Persistent or network failure stays unknown and cannot promise immediate remote preference enforcement. Full Flutter/analyze/platform gates remain root-owned on the shared integrated candidate.

### Actual composition integration correction and final settings gate

The real settings widget imports main and exposed a R5a integration omission: _ManagedPusherGateway did not implement the new list() interface. Scoped analyzer/pure service tests did not cover that transitive compilation. dnd-settings-integration-compile-failure.txt and managed-pusher-integration-red.txt preserve this failure; neither is a successful behavior RED. The file owner independently committed c05b2f17378214e8ddd374db54f8832a8244215a, cherry-picked here as a854ea64, adding SDK list through the existing lifecycle admission plus a post-await revoke check and null-as-unknown. No R7b media changes are included in that wrapper commit.

managed-pusher-integration-green.txt initially passes the actual managed SDK wrapper. dnd-settings-managed-green.txt then passes 10 tests: real settings/main compilation, iOS-only policy wording, Android nonappearance, existing settings regressions, SDK list during resource opening, null-as-unknown, no SDK read after revoke, and a delayed SDK result rejected after resource cancellation. dnd-settings-red.txt records the intended iOS text absence with Android case passing after wrapper integration. Test-authoring setup issues (foundation debug override restored too late, then an import inserted below declarations) were corrected in tests; they were not reported as product failures or passes. Repository and deployment policies also pass in dnd-{repository,deployment}-policy.txt.

The final nine-file analyzer explicitly includes matrix_e2ee_client.dart and the new real-wrapper test, to cover the earlier scoped-analysis omission (dnd-final-analyze.txt). Full integrated client checks still belong to root. R7c independent SPEC/domain and quality reports, with independent 17 startup tests, are recorded separately in the root integration artifact; no main/startup source was changed by this agent.
