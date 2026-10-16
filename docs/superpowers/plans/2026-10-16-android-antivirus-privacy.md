# Android installation alert investigation and consent repair

User authorization: 2026-10-16, approved proceeding with the prior P1 investigation, confirmed-risk repair, stable signer and preserved-data upgrade plan. This is a bounded repair inside that scope; no AV evasion or signing rotation.

## Scope and evidence

- Redmi K80 / HyperOS 3.0.308 / Xiaomi Security installation alert `a.gray.BulimiaTGen.f`; engine/build/database and affected sample still missing.
- Confirmed independent defect: Application invokes Getui preInit before persisted consent. Current official integration guide requires both initialization and CID registration after consent: https://docs.getui.com/getui/mobile/android/androidstudio/ . This does not establish the installation alert's cause.
- Keep package/certificate/private key, permissions, SDK versions, delta integrity, account/E2EE data and iOS behavior unchanged.

## Owned files

- Android ChatFlowApplication.kt, MainActivity.kt, one native consent helper and its tests.
- Comments describing the old preInit timing in app_home.dart, getui_push_token_provider.dart, AndroidManifest.xml and push-setup.md.
- This plan, existing antivirus task/current-state and this task's verification artifacts.

## Execution

1. Record initial artifact identity, manifest permissions/components, SDK provenance and connected devices. Avoid copying secrets or user data.
2. RED: exercise actual Application startup with SDK boundary instrumentation; missing/false persisted consent must produce no SDK calls, true must retain preInit. Add native entry guard tests for malformed consent and accepted initialization ordering.
3. GREEN: centralize native persisted-consent read, fail closed; guard Application preInit and MethodChannel initialize, performing preInit before initialize when consent is first granted. Keep legacy persisted consent key and existing-session migration unchanged; separately record migration limitations.
4. Run focused and related Android unit tests, build compile, targeted privacy/update checks. Preflight verify.ps1; do not import production .env. Reuse unchanged shared Flutter results for comment-only Dart changes.
5. Specification then quality review. Prepare a vendor review dossier without claiming an AV pass or publishing unverified mitigation. Root cause still needs original sample/details and K80 retest.

## Acceptance and rollback

- No application-side preInit/initialize before consent; persisted true retains background startup preparation. Corrupt/missing consent and SDK exceptions do not crash chat.
- Official package stays com.liuhetong.mobile and certificate SHA256 75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff. Any later delivered candidate increments versionCode and undergoes normal rebuild/sign verification and old-version upgrade.
- Native tests do not substitute for vendor-library network instrumentation, real push delivery or Xiaomi installation detection.
- No global publication until candidate evidence is adequate. Revert only this repair if it regresses initialization; never uninstall/clear user data. Already upgraded devices require a higher-build recovery package rather than assumed downgrade support.
