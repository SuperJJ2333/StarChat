# Incoming call permission/notification delivery

User scope and approved plan: `docs/superpowers/plans/2026-09-05-incoming-call-permission-dedup.md`. Work continued past local midnight. Evidence retained in the same named task folder `artifacts/2026-09-05/incoming-call-permission-dedup/`.

## Delivered

- Mandatory future Android packaging workflow documented in `docs/runbooks/android-apk-rebuild.md`, referenced by AGENTS.md and both release runbooks. Stable user-tested certificate retained. Historical CI source outputs are explicitly intermediate and cannot be published directly under the new policy.
- Matrix SDK media capture moved from invite initialization to consented answer. Local version-pinned 0.34.0 dependency keeps 176 upstream lib files, with only call_session.dart modified. Upstream license, analyzer configuration, source hashes and minimal patch are retained. No crypto algorithms or signaling payload changes.
- Permission refusal keeps incoming call ringing/actionable, restores native answering to ringing, and does not dismiss its notification. Settings/retry/reject remain available.
- Generic local wake notification is deferred, resolved/cancelled on local message or call classification, and protected against cancellation/disposal races. Encrypted events already resolved locally as call signaling are excluded from chat notifications. App composition root triggers sync and treats permission-request/connection phases as active calls. Voice notification title standardized to 语音通话; video 畅聊视频来电.
- Review caught a termination race while capture or stopRingtone was pending. New guards cover kEnding/kEnded after asynchronous answer steps, coalesce concurrent answers and release late media. Red/green race tests and re-review passed.

## Executed verification

- SDK pre-fix regression failed in initWithInvite→_getUserMedia for both voice/video, proving the missing-permission suppression before UI. Initial test harness signature mismatch corrected before recording behavioral red evidence.
- Permission/controller/widget focused agent suite: 78 passed; integrated SDK/controller/UI/coordinator tests: 62 passed (`integrated-call-tests.log`). SDK coverage includes no capture on ringing, denied answer preserving ringing, authorized voice capture before answer, duplicate answer coalescing, ending/ended during capture, and termination while stopping ringtone.
- Notification coordinator/title/source suites: 22 passed with behavioral red evidence (`notification-*` logs).
- JVM native tests: eight passed (four presentation/state, one denied-media CallStyle construction, three pending actions). Native full-screen/content intents exist despite mic/camera denial in the framework test.
- Changed-file Dart analysis passed. Repository `scripts/verify.ps1` passed (`verify.log`); no backend code or production DB changes.
- Source release build succeeded. Conventional Apktool 2.12.1 decode/build succeeded; final aligned signature verifies v2/v3 and matches the user-tested certificate. Re-decoded smali matches all 24,570 classes after narrow default-static-value normalization; all 331 native/asset entries match the source build, normalized manifest identical. All five DEX and resource table were rebuilt.

## Test APK

Path: `artifacts/2026-09-05/incoming-call-permission-dedup/rebuild-0341/ChatFlow-0.3.41-arm64.apk`.

- Package com.liuhetong.mobile, version 0.3.41, APK versionCode 2044, ARM64 only.
- Size 75,273,156 bytes.
- SHA256 `9e18eeb5d60353f24e079828581278d4b066052f87a3dd700cb9c59a41529788`.
- Certificate SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`, same as user-tested rebuilt 0.3.40. Should support normal update from that exact signed installation, subject to device validation; old official/debug signers differ.

No automatic installation, app uninstall/data clearing, production update-popup publication or real-recipient call occurred. User device installation, scanner result and actual cross-account calls remain unverified for this new APK.

## Remaining conditions

The Getui OEM offline generic notification uses a provider-generated random ID and cannot be correlated to the decrypted call under the current type-less push contract. This local fix does not claim that a process-dead OEM alert can never briefly show generic text. Offline correlation/background execution needs further design and vendor credentials. Actual message offline fallback was not globally disabled.

Microphone/camera permission is now independent of ringing; notification/full-screen/OEM background permissions still govern OS presentation. A unit test of CallStyle is not a guarantee that HyperOS will always launch an activity.

Architecture explanation and supported Telegram/WhatsApp comparisons: `docs/verification/2026-09-06-call-architecture-review.md`. Existing Android build deprecation warnings remain; no new warning suppression was introduced.
