# iPhone 15 simulator compatibility investigation

User authorized selecting possible iOS versions; the failing phone's OS is unknown. The reported build is the website enterprise re-sign of 0.3.53 (59), also working on the user's iPad and iPhone 8.

## Scope and limitations

Cloud diagnostics build original source for fresh iPhone 15 simulators, using four-second synthesized tones and generated video patterns. No production account, messages, attachment plaintext, or recovery keys are involved. A simulator cannot execute the device-only enterprise IPA or validate its injected libraries/signature/Keychain entitlement differences. Playback progression does not prove physical speaker audibility. These tests are not an end-to-end encrypted attachment delivery test.

The workflow selects available iOS 18 and 26 runtimes, recording exact versions rather than assuming them. First actual selection: iOS 18.6 / Xcode 16.4 and iOS 26.2 / Xcode 26.3 on macos-15-arm64.

## First cloud run

Run https://github.com/SuperJJ2333/StarChat/actions/runs/34226678992, source 913569c8c3e29f5bb51e27b3d3a7521e6b304c0d.

Neither runtime reached assertions. Both initial builds failed to link Pods_Runner. Second builds exposed a Swift architecture error on iOS 18 and a test connection closure on iOS 26; the latter also explicitly warned that mobile_scanner's MLKit dependency lacks arm64 simulator support. These are harness/build failures, not evidence of failed history retention or media decoding.

Second diagnostic revision 6ec2093930e880ec4b106d88977626db4f90d8a3 configures CocoaPods before testing and disables SPM plugin integration. It removes only mobile_scanner from the CI dependency list, retaining actual media, SQLCipher, secure storage and app native bridges. Consequently scanning and the full shipped plugin combination are outside this diagnostic run. Release source/dependencies and website IPA are not changed by the CI-only exclusion.

## Native failures reproduced and candidate corrections

Run https://github.com/SuperJJ2333/StarChat/actions/runs/34237881440 reached assertions on both runtimes. Each seed phase reports **11 passed / 4 failed**:

- M4A and raw AAC: direct player, production system route and production earpiece route all initialized and advanced.
- WAV: direct player with `audio/wav` passed, while both production engine routes with null MIME failed with `DarwinAudioError` / AVPlayerItem source failure.
- H264 and HEVC: named `.mp4` files passed; identical extensionless file bytes failed with `VideoError`, OSStatus -12847.
- Native Keychain and SQLCipher seed phase passed. This alone is not a restart test.

The run was intentionally cancelled after identifying Flutter3.44.9's default `test --uninstall=true`, which invalidated the originally intended retention check. Both phases now explicitly use `--no-uninstall`. The next run checks the seeded database is still present before rebuilding/reopening the verify phase, sets per-test/per-step timeouts, disables optional DDS, and collects simulator console/crash diagnostics.

Candidate WAV fix recognizes both RIFF and WAVE signatures and supplies `audio/wav`, without changing bytes or existing AAC/M4A handling. A local regression failed before the change and passed afterward; another RIFF format is not mislabeled as WAV.

Candidate video fix routes `resolveCachedVideoFile` through `MediaCache.preparePlaybackFile`. Recognized MP4/QuickTime caches are renamed in place to a fixed `.mp4`/`.mov` suffix, preserving/recreating the length sidecar and using the same governed cache. Existing typed entries are reused, unknown/HEIC files are not mislabeled, corrupted caches still trigger recovery, and no second media copy is retained. Native verification now uses this actual production resolver rather than expecting the raw plugin's extensionless behavior to change.

Both media changes passed specification and subsequent independent quality/security review. The combined candidate's 46 focused tests passed; seven changed/test Dart files analyzed with no issues. The reviewed fixes and associated regression files are also synchronized to the main workspace. Its old voice file differed only by the previously delivered build59 MIME/error-handling fix; that verified fix was retained with the WAV addition.

Third run: https://github.com/SuperJJ2333/StarChat/actions/runs/34241630843, source **4b405bff6d9926b6774a99ae267fc62449a4f4f2**. Both runtimes completed all **15 seed assertions and 2 cross-process verification assertions successfully**. Logs show all three audio containers/routes and both named/cached video codecs initialized and advanced; the native original Keychain key/session and SQLCipher record survived stopping/reinstalling-without-uninstalling/reopening the app.

The workflow itself remained red: each invocation added one **test-loader** error, `streamListen: invalid 'streamId' parameter: integration_test.VmServiceProxyGoldenFileComparator`. No application assertion failed. Local Flutter source (`flutter_platform.dart`, `_listenToVmServiceForGoldens`) confirms this comparator subscribes to a custom DDS stream, incompatible with the diagnostic `--no-dds` override. Fourth revision **f0e594525144a5f4f46379a7c86b13922ad00612** removes that override and verbose build output; application/test code is unchanged. This is a test-runner correction, not a waiver of nonzero test exit codes. Final run https://github.com/SuperJJ2333/StarChat/actions/runs/34244984251 subsequently succeeded on both runtimes; see final verification below.

## Proven direct-room timeout defect

Two fake-backend tests reproduced failures before the fix: (1) a known canonical room times out while local sync is absent, incorrectly creating a replacement; (2) registration selects a conflicting canonical room whose open times out, incorrectly returning the replacement.

The candidate rethrows TimeoutException only when opening an already selected canonical room. Registration-request fallback is unchanged. Unsafe-room recovery and encryption/member validation are unchanged. No room is deleted or merged, and no E2EE/key persistence behavior changes.

Focused verification: 36 tests passed after the fix; changed Dart files and integration test analyze without issues. Specification review and subsequent independent quality/security review passed. A further 59 media/cache/session tests passed. Further transport errors, directory lookup outages, and concurrent first-ever creation remain outside this bounded fix.

## Remaining history-loss hypothesis outside the native storage probe

Read-only startup audit found an existing, separate path: `SessionBootstrapController._bootstrap` calls `_bestEffortMatrixReset` when Matrix sync returns `M_UNKNOWN_TOKEN` or `M_FORBIDDEN`; `MatrixSdkE2eeClient.resetLocalStore` invokes `MatrixClientFactory.reset`, which deletes the Matrix database and its SQLCipher key. Normal business logout uses `suspend/reopen` and preserves them. There is no evidence that the failing iPhone took the reset branch, but native Keychain/SQLCipher retention success does not rule it out. The synthetic integration entrypoint does not exercise authenticated bootstrap or encrypted room-key recovery.

No authentication/E2EE recovery behavior is changed in this candidate. A change to that flow requires the repository's protected-change ADR and domain/security reviews; it must preserve account isolation and handle reauthentication, rather than merely removing the reset call and leaving stale credentials active. This remains a follow-up diagnosis, not a confirmed cause on the user's unavailable phone.

## Evidence

Local artifacts: docs/verification/artifacts/2026-09-08/iphone15-compatibility/ (red/green test logs, sanitized synthetic cloud logs, runtime inventory, publication allowlist). Diagnostic source lives in the isolated ios-0353/source checkout (mapped T:). The reviewed direct-room fix and regression were also copied into the main workspace after confirming its source matched the original baseline; unrelated root files were not copied or deployed.

The isolated candidate's `pwsh -NoProfile -File scripts/verify.ps1` completed with exit 0 and `Verification: PASS`, including a final run after all production fixes: repository/deployment policies, infrastructure tests, 349 backend/worker tests (19 skipped), 66 Flutter boundary tests, UI/OpenAPI drift, offline migration SQL and Compose rendering passed. Existing FastAPI/Starlette and Pydantic deprecation warnings remain in this baseline; these do not test a physical iPhone.

## Final verification, 2026-09-09

Run https://github.com/SuperJJ2333/StarChat/actions/runs/34244984251 completed successfully at commit f0e594525144a5f4f46379a7c86b13922ad00612. Both jobs succeeded: iOS 18 job 102124555636 and iOS 26 job 102124556076. Downloaded final artifacts are retained under `artifacts/2026-09-08/iphone15-compatibility/run-34244984251/`.

Each iPhone 15 simulator (iOS 18.6 and iOS 26.2) passed all 15 seed tests and 2 separate-process retention tests, with `All tests passed!` in both phase logs and no test-loader failure. The default DDS configuration resolves the preceding diagnostic runner failure. These results validate the bounded media corrections and synthetic native storage retention; the unavailable phone's authenticated history-loss and enterprise re-sign behavior remain unconfirmed.

The reviewed production fixes are synchronized to the main workspace. No new IPA has been built or released by this work; the website package remains 0.3.53 (59).
