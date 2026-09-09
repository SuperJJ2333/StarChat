# Redmi Debug 2076 delivery

User authorized installation of the Moments UI update on Redmi.

- Source: `d5ffea72`, branch `codex/redmi-polish-20260909`.
- Device: Redmi Note 7, serial `cbd0156b`.
- Version: **0.3.72-debug / 2076**, package `com.liuhetong.mobile`, standard ARM64 full application.
- Source build preserved Business API, Matrix and Getui HTTPS definitions pointing to `https://liuhetong888.com`.
- Apktool 2.12.1 full decode/rebuild/redecode, build-tools 36.0.0 alignment and signature verification passed. Same existing Redmi Debug certificate: `34999c8b561affc263f11df0a3865e8c03c0386997a8c37bd12110380e5bc1f1`. No new signing key.
- 26537 smali classes preserved; 338 native/Flutter assets byte-identical; manifest semantics identical. Source and final ZIP checks confirm ARM64 and genuine Debug kernel.
- Final APK SHA256: `fa7298f331f365694d84dd5fc6caebfb4f2e0e5a71d20fd162102262feb0f9fc`; size 142371666 bytes. Local, phone Download copy and installed base.apk hashes match.
- Device file: `/sdcard/Download/ChangLiao-0.3.72-debug-2076.apk`.
- `adb install --no-streaming -r` returned **Success**; PackageManager reports 2076 / 0.3.72-debug. Launch returned **Status: ok**, process PID 9833 at verification.
- No uninstall, data clear, downgrade, test harness or normal-package flutter drive was used. Existing app data was retained by the update operation; content/login recovery was not separately inspected.
- Final local artifact: `docs/verification/artifacts/2026-09-10/moments-redmi/redmi-2076/final.apk`; build, rebuild, signature, manifest, hash, install and launch evidence are in that task artifact directory.

This verifies installation and startup, not complete device interaction/performance coverage. The user can inspect the new Moments UI. Server privacy/GIF changes remain undeployed; this task did not publish an Android release update or iOS update. Source validation is documented in `2026-09-09-moments-reactions-ui.md`.

The source build emitted the existing Flutter warning about plugin KGP migration; it completed successfully. An initial command at repository root stopped before compilation because pubspec.yaml is under apps/mobile_flutter; the build above was then executed successfully from the Flutter directory.
