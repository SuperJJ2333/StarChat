# Video Transcode Diagnostics, Four-Digit Build, and LDPlayer Debug Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development or executing-plans. Each executable change begins with a focused failing test. Specification review precedes quality/security review.

**Goal:** Make the measured MI 6 video failure actionable without weakening the existing video policy, display the full four-digit Android build, and deliver a verified Debug package to LDPlayer.

**Architecture:** Extend the existing `PerformanceTrace` with at most two typed, local-only video attempt summaries. Android video_compress returns closed failure/cancel codes without exception text; Dart preserves them and the existing normal-then-aggressive path records each attempt. The existing server upload JSON remains byte-compatible. Android build normalization removes ABI offsets only when they match the compiled build. Build a separately signed parallel Debug application for the emulator while leaving its old differently signed main package intact.

**Tech Stack:** Flutter 3.44.9 / Dart 3.12.2, Kotlin Android plugin, existing `PerformanceMetrics`/`ChatDiagnostics`, Apktool 2.12.1, Android build-tools 36, ADB.

**Authorization and boundary:** The user requested the optimization, four-digit build display, and LDPlayer Debug test on 2026-09-26. Do not publish a production API/client, alter E2EE, change the 20 MiB encoded-output limit, send original video after compression failure, log media paths/content/native exception messages, or modify MI 6. Existing evidence: `docs/verification/artifacts/2026-09-26/debug-jank/device-findings.md` in the 2178 worktree. The production diagnostic receiver rejects unknown wire fields, so new attempt details stay local to Debug VM snapshots.

## File ownership

- Build worker: `apps/mobile_flutter/lib/core/app_config.dart`, `test/core/app_config_test.dart`, `pubspec.yaml`, matching build contract only if needed.
- Plugin worker: `third_party/video_compress/android/src/main/kotlin/com/example/video_compress/VideoCompressPlugin.kt`, `third_party/video_compress/lib/src/video_compress/video_compressor.dart`, focused plugin-channel test.
- Root: `lib/core/performance_trace.dart`, `performance_trace_model.dart`, `test/performance/` cases, `features/matrix/video_transcode.dart`, focused matrix video tests, task/verification docs, integration, build, emulator.
- Workers must not edit each other's files concurrently. All paths above are relative to `apps/mobile_flutter` unless under `docs/`.

## Task 1 — Four-digit runtime build

- [ ] Add a failing runtime `PackageInfo.setMockInitialValues` test: a non-split Android `2179` must remain `2179` in `AppConfig.appBuildNumber`; a split code equal to compiled build plus 1000, 2000, or 4000 maps to the compiled build; unrelated four-digit codes remain unchanged. Assert the value used by About/diagnostics/update routing is the same full integer.
- [ ] Run `C:\src\flutter\bin\flutter.bat test test/core/app_config_test.dart` and record the expected `2179 → 179` failure before code changes.
- [ ] Change normalization to compare against a compiled build constant rather than apply `% 1000` to every code. Keep the pubspec/build contract and iOS behavior. Set `pubspec.yaml` and the AppConfig fallback to `0.4.13+2179`.
- [ ] Rerun the focused test and `python tests/mobile/test_app_build_contract.py`; record exit codes. Do not change update server settings.

## Task 2 — Safe native video failure code

- [ ] Add a failing Dart MethodChannel test: Android `PlatformException(code: 'video_transcode_failed')` and `video_transcode_cancelled` must reach the caller as closed typed outcomes; raw exception text and source path must not appear in diagnostic output. A legacy `null` result remains supported for iOS/older plugins.
- [ ] Run the focused Flutter test and record its expected failure because the current `_invoke` swallows `PlatformException`.
- [ ] Change only the Android plugin's failed/cancelled callbacks to `result.error` with fixed codes and null message/details. In the Dart plugin map only those codes to a typed failure class; other platform errors become typed unknown. Remove the raw `debugPrint` of `PlatformException`. Do not expose `Throwable.message`, stack, path, URI, codec, or media data.
- [ ] Rerun the channel test and compile the Android Debug Kotlin sources. The existing successful MediaInfo contract and cleanup must remain intact.

## Task 3 — Bounded per-profile trace and truthful classification

- [ ] Add failing tests to `test/performance/` for at most two typed `normal`/`aggressive` attempt records, measured durations/outcomes, idempotent finish, local VM JSON containing only closed values, upload `toJson()` excluding all new fields, and a failed video trace with `videoTranscodeStarted` but no `videoTranscodeDone` classifying as `media_transcode` from the measured start-to-failure interval.
- [ ] Run the focused tests and record expected failures.
- [ ] Extend `PerformanceTrace`/`PerformanceRecord` with a fixed-capacity typed attempt list. `recordVideoTranscodeAttempt(profile, outcome, duration)` must be synchronous O(1), accept no arbitrary string/map, and copy into `withFrameAttribution`. Add `video_transcode_attempts` and `transcode_until_failure_ms` only to `toLocalDiagnosticJson`; keep `toJson` and server schema unchanged.
- [ ] In `video_transcode.dart`, use a `Stopwatch` around each actual profile attempt and record success, native failure, cancel, missing/invalid output, or over-limit using the closed enum. Keep the two-pass policy, encoded output limit, temporary cleanup, original retention, and `videoTranscodeDone` only on success. Do not infer a specific codec/device error from the MI 6 record.
- [ ] Run focused video policy, trace, privacy, and classifier tests; confirm legacy `null` still triggers the second pass and both-pass failure never uploads an original.

## Task 4 — Verification, packaging, and emulator

- [ ] Preflight source SHA, lock SHA, Flutter/Java/build-tools/Apktool/signing material, disk, and both ADB devices. Verify only `emulator-5556` is targeted; preserve MI 6.
- [ ] Run focused Flutter tests, `flutter analyze lib test`, `flutter test test/features/matrix`, full `flutter test`, relevant native compile, and `pwsh -NoProfile -File scripts/verify.ps1` after `.env` preflight. Reuse unchanged gates only where the delivery workflow permits; report every real exit code and baseline failure.
- [ ] Review specification compliance first, then quality/security. Confirm server wire JSON is unchanged and no path/content/exception text enters diagnostics.
- [ ] Build `0.4.13+2179` Debug for arm64 with explicit `--android-project-arg=chatflowParallelDebug=true`, HTTPS Business/Matrix/Getui defines, then perform source APK → Apktool DEX/resource/manifest rebuild → zipalign → fixed signing → final package/ABI/assets/manifest/signature checks per `docs/runbooks/android-apk-rebuild.md`.
- [ ] Require final package `com.liuhetong.mobile.debug`, code 2179, fixed certificate `75b31c66…ba61fff` before `adb -s emulator-5556 install -r -t --no-streaming`. Do not uninstall or overwrite the emulator's `com.liuhetong.mobile` old-signature app.
- [ ] Launch the parallel app and verify installed package/version, first-run startup/crash state, four-digit build value via safe runtime evidence, and a synthetic video channel/trace case. Authenticated message/video send requires a user session; report it as untested if unavailable, never claim a real send passed.
- [ ] Record artifact SHA, signing channel, emulator evidence, current branch/commit, timing ledger and remaining limitations in a separate task record under `docs/workflow/tasks/` and verification report under `docs/verification/`.
