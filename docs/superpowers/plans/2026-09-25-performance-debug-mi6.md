# MI 6 performance diagnostics Debug delivery and measurement

**Authorization:** User request on 2026-09-25 to install a Debug build on MI 6 and assess client/network performance. No public Android/iOS release, production API deployment, message send, financial write, or call to another person is requested.

**Baseline:** Device `cbd0156b` currently has `com.liuhetong.mobile` 0.4.10/2171 Debug with preserved data and APK SHA-256 `5f3ddee5e9396a31efb16c3aff9c185937f5203bb9b5f950825f1561148aaf20`. The standalone diagnostics commit `8d044655` is based on 2165; use released Android source `e7ba46a4` (2172) and integrate it in the isolated `codex/performance-debug-mi6` worktree. The 2173 iOS retained-identity recovery commits are outside this Android candidate.

## Delivery steps

- [ ] Resolve diagnostics cherry-pick conflicts by retaining 2172 navigation, contacts, profile, and room behavior; run focused tests, final Flutter analyze and full Flutter test on the integrated inputs.
- [ ] Assign a new Debug version/build above installed 2171 and released 2172, keeping `pubspec.yaml` and `AppConfig` in sync. Freeze source and lock hashes; preflight device, tools, free disk, signer and three HTTPS dart-defines.
- [ ] Build ARM64 `standard` Debug with `CHATFLOW_PERFORMANCE_METRICS=true`; use the source APK only as the intermediate. Rebuild with Apktool 2.12.1, align using build-tools 36.0.0, sign with the existing user-tested identity, and verify manifest/ABI/DEX/resources/native assets/Flutter assets/signature.
- [ ] Recheck the device baseline; use `adb install -r` to preserve app data. Verify the installed APK SHA, version, signer continuity, original first-install time, launch and crash buffer.
- [ ] Read `ext.chatflow.performance` from the Dart VM service. Exercise safe local navigation and lifecycle paths, inspect frame, operation, Matrix/network, media and API evidence without collecting message content or identities. Do not send messages, initiate calls or financial actions.
- [ ] Record measured bottlenecks, unsupported metrics and optimization opportunities in a separate task record and `docs/verification/` report. Distinguish measured device facts from test coverage and user interactions still required.

**Safety:** No downgrade, uninstall, data clear, arbitrary new signing key, sensitive log dump or unverified timing estimate. Keep all temporary artifacts below `docs/verification/artifacts/2026-09-25/performance-debug-mi6/`.
