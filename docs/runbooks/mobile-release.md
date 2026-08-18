# Mobile release runbook

Required GitHub Actions secrets: `IOS_CERTIFICATE_BASE64`, `IOS_CERTIFICATE_PASSWORD`, `IOS_PROFILE_BASE64`, `IOS_PROVISIONING_PROFILE_NAME`, `APPLE_TEAM_ID`, `IOS_BUNDLE_ID`, `APPSTORE_ISSUER_ID`, `APPSTORE_KEY_ID`, `APPSTORE_PRIVATE_KEY`.

The workflow generates the iOS host project on macOS, runs Dart checks, imports signing assets only in the ephemeral runner, builds the IPA, and uploads it to TestFlight. No certificate, profile, private key, or IPA is committed.

Every pull request also runs the unsigned `simulator-build` job on `macos-14`: `flutter pub get`, `flutter analyze`, `flutter test`, then `flutter build ios --simulator --no-codesign`. This job requires no signing secret and must pass before merge. The TestFlight job remains limited to version-tag pushes or manual dispatch and only accesses signing secrets after the checks pass.

The TestFlight job validates Team/Bundle/profile secrets, updates the generated Xcode project, and generates `ExportOptions.plist` inside the ephemeral runner before building the IPA.

Android release disables cleartext traffic. Only `src/debug/AndroidManifest.xml` enables HTTP for local `adb reverse` and emulator acceptance; production Business API and Matrix build parameters must use HTTPS.

## Public-domain Android build

The `liuhetong888.com` release must be built only after the public gateway,
certificate, Business API health endpoint, Matrix versions endpoint, and
Matrix well-known response pass external verification:

```powershell
flutter build apk --release `
  --dart-define=LIUHETONG_BUSINESS_API_URL=https://liuhetong888.com `
  --dart-define=LIUHETONG_MATRIX_HOMESERVER=https://liuhetong888.com
```

Do not append `/api/v1` to `LIUHETONG_BUSINESS_API_URL`; the typed client owns
that path. Do not publish an APK containing `localhost`, a LAN address, or an
HTTP production endpoint.
