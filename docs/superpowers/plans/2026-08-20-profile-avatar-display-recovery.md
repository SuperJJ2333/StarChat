# Profile Avatar Display Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the uploaded profile avatar through the shared cache-backed `UserAvatar` on the “我” identity card rather than a separate `Image.network` path.

**Architecture:** The server remains the authoritative source: completion returns a signed `avatar_url`, and `ProfileController` replaces its state with that response. Every Flutter profile surface uses `UserAvatar`, which keys the cache by stable user seed plus returned URL; a changed signed URL therefore requests the newly uploaded object while retaining the existing textual fallback only for absent or failed images.

**Tech Stack:** Flutter/Dart, `cached_network_image`, `flutter_test`; FastAPI API profile tests for the server contract.

---

### Task 1: Prove the completed upload returns an avatar URL

**Files:**
- Test: `tests/business_api/identity/test_profile_api.py`

- [x] **Step 1: Run the existing end-to-end avatar upload API test.**

Run: `py -3.12 -m pytest tests/business_api/identity/test_profile_api.py::test_avatar_upload_accepts_real_square_jpeg_png_and_webp -q`

Expected: PASS; it proves `begin -> content -> complete` returns non-empty `avatar_url` and persists its private object reference.

### Task 2: Protect identity-card rendering from bypassing the shared avatar component

**Files:**
- Modify: `apps/mobile_flutter/test/features/profile/profile_controller_test.dart`
- Modify: `apps/mobile_flutter/lib/features/profile/profile_page.dart`

- [x] **Step 1: Write a widget regression test using a completed profile with `avatarUrl`.**

Assert that `ProfileExperiencePage` finds one `UserAvatar` at `Key('profile-identity-avatar')` and that its `avatarUrl` equals the completed profile URL.

- [x] **Step 2: Run the new widget test to verify RED.**

Run: `C:\src\flutter\bin\flutter.bat test test/features/profile/profile_controller_test.dart --plain-name "me page identity card uses the shared avatar renderer for an uploaded avatar"`

Expected: FAIL because `_IdentityCard` still creates `Image.network` directly and provides no shared avatar key.

- [x] **Step 3: Replace the identity-card conditional `Image.network` tree with `UserAvatar`.**

Pass `nickname`, `fallbackSeed`, and `avatarUrl` from `ProfileData`, set `size: 72`, and attach `Key('profile-identity-avatar')`. Preserve the current 12px rounded-corner presentation in the shared avatar component invocation.

- [x] **Step 4: Run the widget test to verify GREEN.**

Run: `C:\src\flutter\bin\flutter.bat test test/features/profile/profile_controller_test.dart --plain-name "me page identity card uses the shared avatar renderer for an uploaded avatar"`

Expected: PASS.

### Task 3: Verification and delivery

**Files:**
- Modify: `docs/verification/2026-08-19-registration-server-activation.md`

- [x] **Step 1: Run focused backend and Flutter tests.**

Run:
```powershell
py -3.12 -m pytest tests/business_api/identity/test_profile_api.py -q
C:\src\flutter\bin\flutter.bat analyze --no-pub lib/features/profile/profile_page.dart lib/features/profile/profile_controller.dart lib/ui/components/user_avatar.dart lib/ui/foundation/avatar_cache.dart
C:\src\flutter\bin\flutter.bat test test/features/profile/profile_controller_test.dart test/ui/wechat_components_test.dart
```

Expected: all pass without analyzer findings.

- [x] **Step 2: Run repository verification, build, install, and launch the debug APK.**

Run:
```powershell
pwsh -NoProfile -File scripts/verify.ps1
C:\src\flutter\bin\flutter.bat build apk --debug --dart-define=LIUHETONG_BUSINESS_API_URL=https://liuhetong888.com --dart-define=LIUHETONG_MATRIX_HOMESERVER=https://liuhetong888.com
adb -s emulator-5554 install --no-streaming -r apps/mobile_flutter/build/app/outputs/flutter-apk/app-debug.apk
adb -s emulator-5554 shell monkey -p com.liuhetong.mobile 1
```

Expected: verification passes, APK installs successfully, and the app launches.

- [x] **Step 3: Append red/green and verification results to the verification record.**

Record commands, exit codes, and concise results without tokens, signed avatar URLs, or private media paths.
