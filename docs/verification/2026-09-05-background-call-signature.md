# Background calls and signature comparison — 2026-09-05

Approved plan: `docs/superpowers/plans/2026-09-05-background-call-signature.md`. Figma synchronization remains deferred by the user's explicit instruction. No production signing key replacement, app uninstall, business database migration, real-recipient test message or call was performed.

## Findings and implementation

1. Root back now uses FlutterActivity's unhandled root navigation callback to move the task to the background. Child pages retain Flutter navigation. MI 6 three consecutive back presses returned to the launcher while retaining process PID 7843 (`mi6-root-back.json`).
2. Call bridge setup initializes CallManager with applicationContext. Foreground/outgoing calls previously skipped the push receiver initialization path, causing native minimization to return false. Home/app switching requests the overlay; returning to the app preserves deliberate minimization. Robolectric executes actual service/window attachment, duplicate startup, permission denial and terminal cleanup.
3. A dismissible reminder names self-start, lockscreen display, background popups and overlays. OEM settings remain explicitly manual. A deferred attempt retries at a safe foreground/root/idle point; acknowledgment stops reminders and widget disposal cancels the retry. No settings are silently granted.
4. Synapse rejected the previous Getui gateway path; the production pusher table was empty. The canonical `/_matrix/push/v1/notify?provider=getui` helper and fixed-upstream nginx route restore registration. Server route deployed with nginx-only reload; defaults still route to Sygnal. After installing the updated MI 6 app, the database reports one pusher, using the corrected Getui URL (`pusher-registration.json`).

## Verification

Artifacts: `docs/verification/artifacts/2026-09-05/background-call-signature/`.

- Native regression red/green: six JVM tests, including real Robolectric WindowManager attachment and root-back behavior.
- Flutter call suite: 41 passed; push suite: 25 passed; integrated focused suite: 53 passed. Permission reminder/retry: five passed after red evidence. Focused Dart analysis passed.
- Python gateway/bridge tests: 30 passed; repository verify script passed again after final reminder retry adjustment (`verify-final.log`, exit 0, `Verification: PASS`).
- Final release and debug builds succeeded from source, ARM64 only, version 0.3.40 / base build 43 / APK versionCode 2043. Dart obfuscation is absent; R8 and resource shrinking remain disabled; no packer was added.
- Final debug installed over the existing MI 6 app with `--no-streaming -r -t`, then launched. No data clearing.
- Final device recheck confirms 0.3.40/2043; three back presses return to the launcher and retain PID 8472 (`mi6-final-device.json`). App brought back to foreground afterward.
- Specification review preceded quality/security review. Review found a deferred-reminder omission; retry behavior was fixed, tested and re-reviewed successfully.

## Signing comparison

An independent RSA diagnostic key was generated locally outside the repository, in a restricted per-user directory. Its password is protected with Windows DPAPI and passed to signing tools via a temporary environment variable. Existing production key and key.properties were not changed.

The final official and diagnostic APK have identical 986 functional ZIP entries. Only signature artifacts differ; manifest, DEX, native libraries and assets were compared by uncompressed SHA256. Both signatures verify; diagnostic APK alignment passes.

| Artifact | SHA256 |
| --- | --- |
| Official ARM64 | `40b9617f382a358bb9cfdc43d3314a14f9086585522f81227bce11f52bac7463` |
| Diagnostic signature ARM64 | `044aff569e3770f013098d5057a36d126b76fc1f3730a9ffde93bcf8ca743bc3` |
| MI 6 debug | `30e3ddfd7cfb5fb6bddf2477fcabab31ba71ecade2d5f9e3a898f3d0957d75cc` |

Official certificate SHA256: `b4784ac301d54add4157427713b136cb22cefd626e9c7a6092882e145c0b22f6`.
Diagnostic certificate SHA256: `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`.

The user has not supplied the APK processed by Android Modifier, so its exact transformations/certificate have not been compared. The diagnostic is an ordinary new-key signature comparison, not a claim to reproduce that tool's private key or guarantee an antivirus outcome. Different signing certificates normally cannot update an existing installation; the diagnostic is excluded from the official update channel.

## Delivery

- Official download: https://www.liuhetong888.com/downloads/ChatFlow-0.3.40-arm64.apk . Full public download SHA256 matches the local verified official artifact; size 74,892,945 bytes.
- Only latest-arm64 APK alias changed; all other architecture aliases were asserted unchanged.
- Update setting published through the existing admin API script; response `PUBLISH 200`, latest read-back 0.3.40 / 43, `PUBLISH_RESULT PASS` (`update-publish.log`). No database bypass.
- Existing update API has no ABI targeting field. Only the ARM64 artifact was produced, but this does not prove that other architectures cannot see the shared update metadata.

## Practical limits

- Actual encrypted cross-account calls and MI 6/HyperOS recent-task swipe incoming-call delivery were not exercised. Unit/device process checks do not establish end-to-end call delivery.
- Vendor offline push SDK/configuration is still absent. Existing Getui registration is repaired, but all-model delivery after system process reclamation cannot be guaranteed. Xiaomi/OEM application credentials and package/certificate configuration are needed to complete vendor offline integration.
- Event-ID-only encrypted pushes reveal no call plaintext/type; the device must sync and decrypt to determine the actual call. No E2EE boundary was weakened.
- Android OEM settings require user action. The app does not obtain privileged system permissions or override force-stop.
- Existing toolchain/FastAPI/Pydantic deprecation warnings remain documented; no warning suppression was introduced.
