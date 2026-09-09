# Android 0.3.73 / 2077 release — 2026-09-10

Status: final release APK verified; publication BLOCKED by production SSH banner timeout. No upload, application update setting change, latest symlink change, iOS change, or device installation occurred.

Source: codex/redmi-polish-20260909, fixes at b0841f8a, plus pubspec/app_config version metadata 0.3.73+2077. Client fixes and their complete regression results are recorded in 2026-09-10-moments-corrections.md. This release does not deploy pending backend changes.

Artifact: docs/verification/artifacts/2026-09-10/android-release-2077/ChatFlow-0.3.73-build2077-arm64.apk
- Package: com.liuhetong.mobile; versionName 0.3.73; versionCode 2077; ARM64 release, not debuggable.
- Size: 77,207,051 bytes.
- SHA256: 1030c052540e955db6d315eeaf8f90dcb4bd2deb245385150c8ecb67f805a6bb
- Fixed formal signer SHA256: 75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff
- Source Flutter standard release build PASS. Existing Flutter plugin built-in Kotlin migration advisory remains; build succeeded.
- Apktool 2.12.1 decode/rebuild/redecode PASS; build-tools 36.0.0 16 KiB zip alignment and signature verification PASS.
- Semantic verification: 24,573 classes unchanged, 337 native/assets entries unchanged, manifest semantics identical; resources rebuilt.
- Version contract tests: 2 passed. git diff --check PASS.

Publication preflight: direct SSH to authorized root@207.56.8.8:23421 timed out during banner exchange with 15 and 45 second limits; configured HTTP proxy also timed out. Initial configured proxy executable lookup failed, corrected to its existing absolute path before retrying. HTTPS download endpoint returned 200 with previous APK size 77,010,443 bytes. Production settings could not be read, so their current values are not claimed as verified.

Prepared release-settings-2077.py passed Python compilation; it has NOT run on production. When SSH is restored: inspect and persist previous settings/latest target, upload immutable APK, verify server and public SHA256, apply audited SettingService update preserving actual minimum supported build, atomically switch latest-arm64.apk, verify client update projection/audit and public latest hash. Preserve old APK and rollback settings. Never use a newly generated signing key.

Redmi currently has the differently signed 0.3.73-debug / 2077 build. Do not uninstall or clear it to install this release. No formal device validation is claimed.