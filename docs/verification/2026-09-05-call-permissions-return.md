# Call permissions and return to call — 0.3.39

## Confirmed causes and changes

- AppHome's outgoing route cleanup called hangup when the page popped. Navigation now only releases its own presentation token; a delayed old start/cleanup cannot modify a new route. Only explicit hangup/reject or the actual session ending terminates media. Attempts to start another call restore the current active one.
- CallPage has a minimize control; Android back minimizes live calls. CallUiManager retains an in-app return entry and respects intentional minimization on resume. Explicit native overlay and notification taps restore the same controller/session. Incoming and outgoing ringing, connecting and connected states have appropriate return paths; incoming ringing does not start microphone/camera service before permission.
- Ongoing notification payload is routed to restoreCall, not mistaken for a room ID. ForegroundServiceArbiter remains the sole ongoing service owner and restores sync ownership when a call ends. Voice requests microphone type only; video additionally requests camera. Delayed notification initialization cannot resurrect ended-call notifications. Explicitly minimized incoming calls use non-full-screen notifications.
- Native incoming-service dismissal still stops only the incoming presentation layer. Its timeout is scoped/canceled so it cannot end an accepted or subsequent call. Overlay requires both an active call and user permission, is non-sticky, and its tap is navigation-only.
- Notification settings now contain a read-only readiness checklist and explicit actions for microphone, camera, notifications, incoming/ongoing channels, Android 14+ full-screen access and overlays. Returning from settings refreshes actual state. Permission-denied call pages retain a settings action. OEM background/autostart and sound/lockscreen configuration remain user-controlled and are described without claiming they were automatically granted.

## Verification

Evidence directory: `artifacts/2026-09-05/call-permissions-return/`.

- 65 integrated Flutter tests passed (call UI, native coordinator, permission checklist, notification routing and service arbitration); nine changed Dart files analyze clean.
- Red evidence includes missing minimize control, outgoing-page automatic hangup, ongoing-call payload treated as a room, outgoing ringing without a notification, and delayed notification resurrection.
- Source contracts for current native coordinator and full-screen video layout replace four obsolete inline-handler/layout assertions; modern-action assertion remains intact. Both affected static test files: 15 passed.
- MI6 `cbd0156b`, SDK 28: read-only checks show CAMERA/RECORD_AUDIO runtime grants and microphone/camera/overlay/notification app-ops allowed. No permissions were forced or revoked, and no real calls to other accounts were made.
- Independent specification review preceded quality review; reported active-call overwrite, route cleanup race, outgoing/incoming ringing fallback and delayed notification races were fixed and re-reviewed without remaining P1/P2 findings.

## Limits

The app requests ordinary permissions or opens the appropriate system settings; it cannot silently acquire system privileges or guarantee full-screen UI against user/OEM restrictions. If both system notification and overlay access are denied, only the in-app return control is available. Cross-device/background/lockscreen media behavior still requires user testing on the affected phones; MI6's permission snapshot and widget/JVM tests are not that test.

The pending ARM64 release is advanced to 0.3.39+42 to include these fixes rather than republishing the immutable 0.3.38 APK. Build/publication evidence is recorded in the artifact directory. Existing official signing and no-obfuscation/no-packing requirements remain unchanged.

## Final delivery

- `scripts/verify.ps1`: **Verification: PASS** (`repository-final-verify.log`). Backend/worker 338 passed, 19 skipped; mobile 58 passed; UI/OpenAPI/policy/infra/render checks passed. An initial run caught the new permission page using the raw scaffold; it was changed to the existing shared scaffold and the gate re-run, without bypassing the assertion.
- Android `:app:testStandardDebugUnitTest`: BUILD SUCCESSFUL (3 JVM tests). Final ARM64 release and debug builds succeeded. Toolchain deprecation warnings remain existing upgrade work; they were not suppressed.
- Formal version 0.3.39 / Android code 2042, only arm64-v8a, non-debuggable. APK size 74,827,409 bytes; SHA-256 `817e4d6d17be0855e0ed5fe822627b6e0fd70ecc17a68c58d37aaeedd8aeeca7`. Official certificate SHA-256 `b4784ac301d54add4157427713b136cb22cefd626e9c7a6092882e145c0b22f6` matches previous releases.
- Public URL: https://www.liuhetong888.com/downloads/ChatFlow-0.3.39-arm64.apk. Server stage and complete public HTTPS response matched the final APK hash. Only latest-arm64.apk changed.
- Audited update API returned PUBLISH 200, LATEST 200 and PUBLISH_RESULT PASS; it advanced 0.3.37/40 to 0.3.39/42. The earlier unsuccessful 0.3.38 popup publication is superseded. No API image, database migration or financial changes were deployed.
- MI6 debug APK installed with `--no-streaming -r -t` (no uninstall or data clearing), version confirmed 0.3.39/2042. CAMERA and RECORD_AUDIO remain granted, MainActivity started. Debug SHA-256 `5ad1886be99fd6f15e5ca14854c7c2ad94c243f953704c74127f79390881e3ff`.
- Existing update configuration is shared across ABIs: this release builds/publishes only ARM64; it does not introduce client-ABI filtering for update prompts.
