# ChatFlow 0.3.38 profile/group and call verification

## Scope and causes

The five profile/group defects were confirmed in production wiring: RoomPage omitted ContactProfilePage.onMessage; group public-profile routing dropped avatar_url; sender labels intentionally used primaryDisplayName (excluding the viewer's remark); four bubble variants disabled avatar navigation for non-contacts. Direct-chat details also opened the add-friend surface for existing friends.

Fixed by propagating the existing canonical encrypted direct-chat action through AppHome/MatrixHomePage/RoomPage, sharing profile routing between details and message avatars, passing the public business avatar URL, and rendering viewer-owned contact.displayName. Avatar mentions and nudge payloads use an independent public name, never the private display remark. No business API, authentication or E2EE changes.

The pending call fix separates native presentation teardown (`callEnded`) from explicit user rejection/hangup (`callRejected`). Dismissing/failing native presentation no longer terminates the Matrix media session. Permission-stage hangup invalidates pending acceptance, and closed native presentation bindings reject delayed actions until a new presentation arrives. This confirms a code-level failure mechanism, not a reproduction on every affected handset.

## Evidence

All artifacts are under `artifacts/2026-09-05/profile-group-fixes/` and `artifacts/2026-09-05/call-dismiss-release/`.

- Profile entry/contacts/canonical direct chat: 36 Flutter tests passed; final merged entry subset: 6 passed.
- Group public profile and message interaction: 15 Flutter tests passed.
- Room wiring and outgoing-private-remark guards: 5 pytest checks, confirmed red then green.
- Native coordinator: 24 tests passed, including two red regressions before the final fix.
- Android `:app:testStandardDebugUnitTest`: BUILD SUCCESSFUL, 3 JVM tests, zero failures. Release unit-test task does not exist in this configuration; the initial attempted task failed and was replaced with the available debug task.
- Changed Dart source analysis: no issues.
- Required repository verification earlier this release: backend/worker 338 passed, 19 skipped; mobile gate had 4 failures. Re-run mobile gate after these fixes: 52 passed, the same 4 failures. They are source-layout assertions in `test_flutter_boundaries.py` and `test_native_call_service_layer.py` expecting old inline call handlers/legacy names and a fixed source substring. Full gate is not green; these failures have not been hidden or bypassed.
- Specification review preceded quality/privacy review. The review caught private remarks flowing into avatar mention/nudge text; those actions now use public identities, and final review reports no blockers. See `profile-entry-review.md`.

## Release constraints

Formal build: 0.3.38+41, standard flavor, ARM64 only; no Dart obfuscation, R8, resource shrinking or packing. Existing official signing key retained. No production API image or migration is part of this release.

Physical cross-account acceptance and all five profile paths still require user device verification; unit/source tests and successful packaging do not substitute for that. The existing update endpoint has no ABI targeting: only the ARM64 artifact/alias is updated; older other-ABI clients may still read the shared update configuration.

## Artifact and publication result

- Signed APK: `https://www.liuhetong888.com/downloads/ChatFlow-0.3.38-arm64.apk`
- Version name 0.3.38, Android versionCode 2041, only arm64-v8a, non-debuggable.
- Size: 74,827,301 bytes.
- SHA-256: `53f15012aac207555b544dfc10accfe058d70e33aeedd4cf232f15ebccad3011`.
- Signing certificate SHA-256: `b4784ac301d54add4157427713b136cb22cefd626e9c7a6092882e145c0b22f6`, matching the preceding official release.
- Server stage, public file and public HTTPS full-download hashes matched; latest-arm64.apk was atomically updated, and other architecture aliases were unchanged (`public-verify.log`).
- Update popup publication was attempted through the existing audited API helper using the same idempotency key on retries. SSH subsequently closed or timed out during banner exchange; the independent public HTTPS status check also timed out/failed handshake. No PUBLISH_RESULT PASS has been received. Popup configuration is **not confirmed published** and must not be reported as successful. The artifact upload/hash verification succeeded before that outage.
