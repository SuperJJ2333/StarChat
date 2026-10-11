# R4 Android FGS actual state and native resource ownership

## Recovery entry

- Authorization: root delegated the approved R4 from `docs/superpowers/plans/2026-10-11-im-reliability-remediation.md`; source implementation/test/commit only. No package build, installation, deployment, signing change or version increase in this task.
- Root additionally accepted keeping the existing 20-minute CPU safety lease, applying the same bound to Wi-Fi, and disallowing background renewal. Foreground recovery may reacquire.
- Base: `5c83a08a09b985146bc507a1608cb2153d361e48`.
- Worktree: `C:/Users/Administrator/.codex/worktrees/im-android-fgs/StarChat`; branch `codex/im-android-fgs`.
- Ownership: notification sync service/arbiter and tests; MainActivity/manifest; new SyncKeepAliveResourceOwner and native tests; pubspec/lock; pinned local flutter_local_notifications 19.4.2 fork. No shared plan/current-state edits.
- Last update: 2026-10-11 10:52 +08:00. Implementation and local checks complete; independent SPEC then QUALITY review and shared candidate gates are next.

## Behavior and evidence

| Acceptance | Implementation | Executable evidence | Device/distribution gap |
| --- | --- | --- | --- |
| Native false/null/exception must not claim acquired | hooks return bool; partial acquisition rolls CPU back | Flutter false/null/exception regressions; native Wi-Fi failure test | Device permission denial not exercised |
| Start denial must not claim running or retain sync locks | arbiter returns applied/denied/stopped; native reply waits for startForeground | Flutter start-rejection and arbiter integration; native start-success/denial/invalid request | Real ROM restriction not exercised |
| Concurrent/late start or acquire after stop cannot revive resources | Dart single-flight + epoch/serialized arbiter; native request IDs and 5s acknowledgement deadline | Dart concurrent/late start/late acquire/new explicit resume; native cancellation/deadline/stale prior request | Process kill/real device scheduling not exercised |
| Timeout/destroy releases without Dart and does not restart | Native release -> stopForeground/stopSelf -> best-effort callback; START_NOT_STICKY; no Dart timer | API35 Robolectric timeout/destroy/repeat/ordering; Dart native stopped lifecycle and no watchdog restart | Device short quota drill and long lockscreen still pending |
| CPU and Wi-Fi lifetime bounded together | application owner, 20-minute native lease; expiry updates locks only | Native idle clock 20min + lock-state assertions; Dart locksReleased preserves actual running | Battery/Doze/OEM delivery unmeasured |
| Call owner isolation | shared FGS stops when OS requires; independent native call service/UI untouched; mic/camera-only starts still use OS permission checks and cannot unblock sync locks in background | Native active incoming-call fixture; two call/sync gate regressions; existing call unit tests; Dart shared owner release after timeout | Actual ongoing call device quota drill pending |

`isDesired`, OS-confirmed `isRunning`, and `locksAcquired` are separate facts. Expired native locks do not imply the FGS stopped. A stopped FGS does not automatically reassert from watchdog or owner release. AppHome's existing paused callback cannot bypass the native post-stop sync gate.

## Commands and outcomes

All commands used PowerShell 7 with UTF-8 no BOM console/pipeline and PYTHONUTF8/PYTHONIOENCODING. Logs here are local artifacts; inputs are in `verified-inputs.json`, native counts in `native-results.json`, fork comparison in `fork-inputs.json`.

- Flutter 3.44.9 / framework 6b182d2c75 / Dart 3.12.2; Windows 10 build 19045.
- Microsoft OpenJDK 17.0.20+8; Gradle wrapper 9.1.0; app compileSdk36 and Flutter targetSdk36; Robolectric4.14.1 tests API35 (existing call fixtures retain their configured API).
- Native wrapper is reused read-only from the primary checkout because it is ignored/untracked in Git. `-p` points to this worktree; all outputs are this worktree's own build directory. Local SDK paths only were written to ignored local.properties; no production secrets/signers were copied.
- `flutter pub get --offline` with `PUB_HOSTED_URL=https://pub.dev`: lock delta is only hosted19.4.2 -> local path19.4.2. Initial inherited mirror attempt changed217 dependencies and was discarded before locked RED; no such upgrade remains.
- `flutter test --no-pub test/core/notification/sync_keepalive_service_test.dart test/core/notification/foreground_service_arbiter_test.dart --reporter expanded`: `flutter-red-locked.log`, exit1, 16 pass/10 intended behavior failures. C05 weak-lock fallback contract was explicitly replaced by refusal-without-locks plus cleanup assertions.
- Native baseline `:app:testStandardDebugUnitTest --tests com.liuhetong.mobile.SyncKeepAliveResourceOwnerTest --offline -x :app:compileFlutterBuildStandardDebug`: `native-red-2.log`, exit1, 2 timeout/destroy failures; expanded compile-only resource-owner contract in `native-owner-red.log`, exit1, 5 intended failures before lock behavior implementation.
- Additional red boundaries: `flutter-resume-red.log` exit1 (new foreground request lost behind old start); `native-stale-red.log` exit1 (old cancelled request stopped successor); `native-call-isolation-red.log` exit1 (2 call-vs-sync gate failures). Each followed by minimal implementation and final green.
- Final `flutter test --no-pub test/core/notification test/features/matrix/call_return_notification_test.dart --reporter expanded`: `flutter-notification-final.log`, exit0, 138 pass.
- Final `flutter analyze --no-pub`: `flutter-analyze-final.log`, exit0, no issues. Later native-only and prose/whitespace changes do not change these Dart inputs.
- Final native command: `gradlew.bat -p . :app:testStandardDebugUnitTest --tests com.liuhetong.mobile.SyncKeepAliveResourceOwnerTest --tests com.liuhetong.mobile.call.* --tests com.dexterous.flutterlocalnotifications.ForegroundServiceLifecycleTest --offline -x :app:compileFlutterBuildStandardDebug`. `native-final-v2.log`, exit0, 24 pass/0 failure: owner8, plugin7, existing call9. It compiles app/plugin Java/Kotlin and native tests; deliberately skips Flutter compilation and does not build an APK.
- `git diff --cached --check`: exit0. Upstream trailing whitespace normalized in only README/CHANGELOG/iOS podspec. Windows staging needed per-command `-c core.longpaths=true`; no global configuration change.

## Preflight issues and required remaining checks

- `scripts/verify.ps1` read/preflight: .env absent; script render smoke requires it. Not run, not reported passed. Shared Flutter full suite and applicable repository gates belong to root's final integrated candidate, avoiding duplicate gates on unchanged inputs. No full app suite claim is made here.
- Initial native invocation excluded a nonexistent packLibs task; corrected to exclude only compileFlutterBuildStandardDebug. The original native-red.log is an environment invocation failure, not behavior RED.
- Upstream plugin's own unit-test target lacked offline Mockito3.10.0/androidx.test:core1.2.0. No dependency upgrade or global cache mutation was used: app's existing JVM target compiles/runs the fork lifecycle contract directly. `native-plugin-contract.log` records that unsuccessful environment probe, not a passing test.
- Initial added Kotlin fixture used an unsupported generic getApplication call; corrected. Two Dart brace lints corrected. Final relevant checks passed. Existing Gradle deprecations/Kotlin compatibility notices, manifest warnings and unrelated existing native-test deprecated API warnings remain in logs; these are not concealed as a warning-free platform build.
- Vendor comparison: only 2 Android Java files change behavior; patch note and 3 whitespace-only upstream files differ. LICENSE bytes match upstream. Dart/iOS/macOS executable source remains unchanged; iOS compilation is not verified in this Windows task.
- No real device quota/device_config change, installation, APK source build/rebuild/signing, power profile, Doze, 8-hour lockscreen, OEM transport or real call test was done. These are explicit release acceptance gaps, not waived.

## Stage timing

| Stage | Observed time +08:00 | Basis |
| --- | --- | --- |
| Context/worktree setup | Start unknown; first recorded preflight10:27:55 | Tool output; native managed worktree created |
| Locked Flutter RED | 10:30–10:32 | Timestamped test diagnostics |
| Native RED / initial implementation | 10:32–10:38 | Gradle logs, initial failed and passing runs |
| Async/call edge regressions and final checks | 10:38–10:51 | Additional RED logs and final green logs; native final22s/analyze22.3s |
| Evidence/commit preparation | 10:51 onward | Source hashes/receipt |

Active reasoning versus tool wait was not separately measured; do not sum overlapping Flutter/Gradle durations into wall time. Shared gates/independent reviews remain root-owned.

## Handoff and rollback

Next executable step: independent specification review of this branch against approved R4, then quality/security review. Integrate only after findings are fixed, run shared candidate gates, and retain device acceptance requirements for release. Rollback is a revert of this bounded source commit (including pubspec path and fork); no schema, server configuration or production state changed. No task-owned background command remains running at handoff.
