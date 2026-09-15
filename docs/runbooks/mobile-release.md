# Mobile release runbook

Android delivery policy (user-confirmed 2026-09-05): follow [the mandatory APK rebuild/signing runbook](android-apk-rebuild.md) after the source build. Commands below create intermediate Android artifacts; they do not by themselves complete the final packaging process.

Required GitHub Actions secrets: `IOS_CERTIFICATE_BASE64`, `IOS_CERTIFICATE_PASSWORD`, `IOS_PROFILE_BASE64`, `IOS_PROVISIONING_PROFILE_NAME`, `APPLE_TEAM_ID`, `IOS_BUNDLE_ID`, `APPSTORE_ISSUER_ID`, `APPSTORE_KEY_ID`, `APPSTORE_PRIVATE_KEY`.

The workflow generates the iOS host project on macOS, runs Dart checks, imports signing assets only in the ephemeral runner, builds the IPA, and uploads it to TestFlight. No certificate, profile, private key, or IPA is committed.

Every pull request also runs the unsigned `simulator-build` job on `macos-14`: `flutter pub get`, `flutter analyze`, `flutter test`, then `flutter build ios --simulator --no-codesign`. This job requires no signing secret and must pass before merge. The TestFlight job remains limited to version-tag pushes or manual dispatch and only accesses signing secrets after the checks pass.

The TestFlight job validates Team/Bundle/profile secrets, updates the generated Xcode project, and generates `ExportOptions.plist` inside the ephemeral runner before building the IPA.

Android release disables cleartext traffic. Only `src/debug/AndroidManifest.xml` enables HTTP for local `adb reverse` and emulator acceptance; production Business API and Matrix build parameters must use HTTPS.

## 版本升级清单（每次发版必做）

版本号必须**成对**修改：`apps/mobile_flutter/pubspec.yaml` 的 `version: X.Y.Z+build` 与
`apps/mobile_flutter/lib/core/app_config.dart` 的 `appVersionName`/`appBuildNumber`。
**必须用脚本升版，不要手工改文件**（0.3.90/2114 以来四次发版 2115/2116/2117/2118 都曾
漏改其中一处打红 android-ci）：

```powershell
pwsh -File scripts/bump_version.ps1 -Version 0.3.91+2118
```

脚本同时改写两处并立即运行 `tests/mobile/test_app_build_contract.py` 门禁；提交前若被
人工绕过，该测试也会在 CI 拦下不一致。

## Public-domain Android build

The `liuhetong888.com` release must be built only after the public gateway,
certificate, Business API health endpoint, Matrix versions endpoint, and
Matrix well-known response pass external verification:

```powershell
flutter build apk --release --split-per-abi --flavor standard `
  --dart-define=LIUHETONG_BUSINESS_API_URL=https://liuhetong888.com `
  --dart-define=LIUHETONG_MATRIX_HOMESERVER=https://liuhetong888.com
```

> 2026-09-02 起工程含 Gradle flavor（`standard`=生产，`minimal`=安全审计
> 诊断构建，见 `docs/ANDROID_SECURITY_AUDIT.md`），Android 构建必须显式
> `--flavor standard`；不带 flavor 的构建会失败。诊断构建额外使用
> `--flavor minimal --dart-define=LIUHETONG_IN_APP_UPDATE=false`。

Do not append `/api/v1` to `LIUHETONG_BUSINESS_API_URL`; the typed client owns
that path. Do not publish an APK containing `localhost`, a LAN address, or an
HTTP production endpoint.
