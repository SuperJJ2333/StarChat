# iOS 0.3.81 / 2085 enterprise publication

User authorized publication after enterprise signing returned. Actual returned file was `docs/verification/artifacts/2026-09-10/platform-release-2085/ChatFlow-0.3.81-build2085.ipa`; the mentioned `for-enterprise-resign.ipa` remains the original App Store input and was not published.

## Delivered

- iOS install page: https://www.liuhetong888.com/download?platform=ios&install=1
- Immutable IPA: https://www.liuhetong888.com/downloads/ios/ChatFlow-0.3.81-2085-enterprise-762fb649.ipa
- SHA256: `762fb649511f6aefdd0411ce347ff9bd6915f38bd6b5d3bd7f3e5d01337d37f2`, 59,846,806 bytes.
- `/downloads/ios/manifest.plist` now advertises bundle `com.liuhetong.liuhetongMobile`, build 2085 and that immutable IPA.
- iOS settings published independently as version 0.3.81/build2085, minimum0 (previously unconfigured, effective0), platform-specific HTTPS install page. Five audited writes under `ios-enterprise-2085-762fb649`.
- Android remains version0.3.80/build2084/minimum3, same APK and symlink. Only its historical/shared URL changed to `/download?install=1` in one separately audited write (`-legacy-bridge`). No Android 2085 publication in this release.

## Legacy transition limit

Old iOS2073 sends no platform and necessarily reads the historical Android/default projection. It sees version0.3.80/2084 and its existing notes, but the new shared HTTPS bridge selects OTA on iPhone/iPadOS and the existing APK on Android. After installation, iOS2085 uses its independent iOS projection. This is a transitional URL repair, not retroactive platform-specific metadata in the old binary. An already cached old dialog should be closed and checked again; the direct iOS page also works.

Browser identification here selects an installation target only, never API authentication or authorization. Explicit platform mismatch, desktop and unknown devices do not auto-launch. The system may require a tap or confirmation; a visible install button remains available if automatic launch is blocked. No automatic uninstall or application-data removal occurs.

## Artifact verification

Enterprise profile: team `ZXB3TS7QD4`, ProvisionsAllDevices, no device list, get-task-allow false, production APNs; expiry 2026-12-03 02:06:44. Same enterprise team/channel as previously published2073. Bundle/version/build/minimumOS16 and audio/voip/remote-notification modes verified.

Statistics HTML SHA256 remains `89eab23270dc87ce6fd07715d9abb2606455d94ce1fc16cd56d2deeaeeafb9d5`, equal to the Android candidate and previously published resource. SQLCipher and code-signature resources present. Non-signature resource parity verified against original2085; changed common files are Mach-O binaries. Added ATHelper.dylib, libutils.dylib and flag are the same known signing-channel additions as2073. The profile/application-identifier mismatch pattern remains as recorded in the2073 report. Windows inspection does not independently establish Apple's cryptographic signature acceptance; actual iPhone installation and keychain continuity remain device acceptance items.

## Production and verification evidence

Evidence directory: `docs/verification/artifacts/2026-09-10/platform-release-2085/enterprise-publication/`.

- Sequential16MiB chunk transfer; each chunk and merged SHA matched before immutable install.
- Live static diff contained only intended iOS labels/links and router integration. All overwritten files, including old manifest, checked against preflight SHA. Android symlink checked before and after writes.
- A concurrent task replaced the API container during preparation. The first install attempt stopped before public writes when the container-local settings backup was absent. Re-read unchanged settings and new baseline; host backup persisted before successful publication. This task did not replace/restart any service or alter schema.
- Actual deployment API baseline: `sha256:44057e8cd2c244ff4fae68bee2ced2de93f386337c09704f3775542000f77f15`; Worker `sha256:7e0e9ffc64c670bf5f144c50357861f9345fa36b7b3236039700e4970823d534`; gateway `sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10`.
- Server AND workstation public HTTPS verification: whole IPA SHA,206 range, manifest2085/XML/no-store, exact static file hashes, old iOS2073 and Android2084 accessibility PASS. nginx configuration PASS.
- SettingService read-back and actual router projections PASS: explicit iOS2085; Android/default2084. Public unauthenticated API returns401 AUTH_REQUIRED. No production user token was created for verification.
- New routing test first failed because module was absent; implementation gives7/7 routing/home/source-contract checks PASS, independently repeated by reviewer. Fixed-destination tests reject caller-supplied URL and platform mismatch.
- Full frontend suite143pass/9fail; nine failures are existing admin-chain/manual-wallet fake-DOM append failures, reproduced in untouched main (44pass/9fail for those two files). No full-suite success claim. Repository verify.ps1 policy/template stages pass, then stops because isolated worktree lacks.env; unrelated backend validation is not claimed anew for this static release.
- Reviewer identified non-resumable settings rollback; fixed and rehearsed against real SettingService in isolated SQLite. Initial setup needed test Settings instead of production secrets; final inspect/apply/verify idempotency, interrupted second rollback transaction/retry, completed rollback idempotency and unrelated drift rejection all PASS. Manifest drift and pre-write Android link checks were also added from review.

## Rollback

Host release/backup: `/opt/starchat/releases/ios-enterprise-2085-762fb649/backup/` (0700 parent), contains original static files and settings snapshot. Original IPA/APK remain served. Restore static files from this backup atomically and remove only the introduced router if desired. Preserve newer unrelated changes by checking current hashes before restoring.

`publish-settings.py rollback` uses SettingService and separate audit traces. If the API container was recreated, first create its `/tmp/ios-enterprise-2085-762fb649` directory and copy `backup/settings-before.json` back there. Initial iOS rows were absent and the model does not allowNULL; rollback explicitly advertises the retained2073 enterprise release instead, plus the previous Android URL. It accepts only this release's exact full/partial rollback states and refuses unrelated drift.

## Acceptance still requiring the user's iPhone

Actual enterprise overwrite installation, own/received voice playback and route switching, logout/save-history/relogin withoutL04, history/keychain continuity and dual-device session replacement. Prior2085 CI and simulator evidence remain in the platform2085 report; no assertion that enterprise-device audio or login was tested here. User has been asked to test without uninstalling.
