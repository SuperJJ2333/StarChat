# Mobile Dual-Session Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep users signed in across process restarts while preserving the same Business session, Matrix device, sync state, and E2EE material until explicit logout or authoritative session invalidation.

**Architecture:** A `SessionBootstrapController` coordinates two public adapters: an atomic secure Business token store/client and an initialized persistent Matrix client. Matrix state is stored in SQLCipher with its random key held in platform secure storage; transient network failures produce an offline-authenticated state and never delete credentials.

**Tech Stack:** Flutter 3.44, Dart 3.12, `flutter_secure_storage`, Matrix Dart SDK 0.34, `sqflite`, `sqlcipher_flutter_libs`, `path_provider`, FastAPI, SQLAlchemy, pytest, flutter_test.

---

## File map

- Create `apps/mobile_flutter/lib/core/session_bootstrap_controller.dart`: pure dual-domain startup state machine.
- Create `apps/mobile_flutter/lib/features/matrix/matrix_client_factory.dart`: SQLCipher database/key creation and Matrix `init()`.
- Create `apps/mobile_flutter/lib/session_gate.dart`: loading, authenticated, offline and login routing UI.
- Create `apps/mobile_flutter/test/core/session_store_test.dart`: atomic record and legacy migration tests.
- Create `apps/mobile_flutter/test/core/business_api_session_test.dart`: refresh/logout contract tests.
- Create `apps/mobile_flutter/test/core/session_bootstrap_controller_test.dart`: startup state tests.
- Create `apps/mobile_flutter/test/features/matrix/matrix_client_factory_test.dart`: factory contract and persistent name tests.
- Modify `apps/mobile_flutter/lib/core/session_store.dart`: versioned single-record Business token storage plus Matrix database key.
- Modify `apps/mobile_flutter/lib/core/business_api_client.dart`: refresh, authenticated retry, logout and session inspection.
- Modify `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart`: expose initialization/login/logout/session state through the public adapter.
- Modify `apps/mobile_flutter/lib/main.dart`: asynchronous composition root and `SessionGate`.
- Modify `apps/mobile_flutter/lib/app_home.dart`: explicit logout UI and callback.
- Modify `apps/mobile_flutter/pubspec.yaml` and lockfile: persistence dependencies.
- Modify `services/business-api/app/modules/identity/tokens.py`: reject refresh for non-active users.
- Modify `tests/business_api/identity/test_tokens_and_recovery.py`: protected refresh regression.
- Create `docs/verification/2026-08-14-mobile-dual-session-persistence.md`: red/green, security review and emulator evidence.

### Task 1: Enforce active-account refresh

**Files:**
- Modify: `tests/business_api/identity/test_tokens_and_recovery.py`
- Modify: `services/business-api/app/modules/identity/tokens.py`

- [ ] **Step 1: Write the failing backend test**

Add a test that issues a pair, changes the user status to `SUSPENDED`, and asserts:

```python
with pytest.raises(AppError) as error:
    tokens.rotate(pair.refresh_token)
assert error.value.code == "ACCOUNT_NOT_ACTIVE"
assert error.value.status_code == 403
```

- [ ] **Step 2: Verify RED**

Run: `py -3.12 -m pytest tests/business_api/identity/test_tokens_and_recovery.py -q`

Expected: the new test fails because `rotate()` currently checks only token family and device state.

- [ ] **Step 3: Implement the minimum guard**

After loading the device and before creating a replacement token, load `User` with `family.user_id` and reject missing/non-`ACTIVE` users using:

```python
user = session.get(User, family.user_id)
if user is None or user.status.value != "ACTIVE":
    self._invalid("ACCOUNT_NOT_ACTIVE", "账号不可用", 403)
```

- [ ] **Step 4: Verify GREEN and commit**

Run the focused pytest command, then commit only these two files with `fix(identity): prevent suspended session refresh`.

### Task 2: Store Business tokens atomically

**Files:**
- Create: `apps/mobile_flutter/test/core/session_store_test.dart`
- Modify: `apps/mobile_flutter/lib/core/session_store.dart`

- [ ] **Step 1: Write failing storage tests**

Use an injected storage abstraction/fake and assert:

```dart
await store.saveSession(accessToken: 'a1', refreshToken: 'r1');
expect(await store.session(), const StoredBusinessSession(version: 1, accessToken: 'a1', refreshToken: 'r1'));
```

Add cases for legacy `_accessKey`/`_refreshKey` migration, incomplete legacy data returning null, `clearBusinessSession()` not deleting the Matrix database key, and stable generation of a 32-byte Matrix database key.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/core/session_store_test.dart`

Expected: compilation fails because `StoredBusinessSession`, `session()`, migration and Matrix database key methods do not exist.

- [ ] **Step 3: Implement the versioned record**

Create a value type and save one JSON value under `liuhetong.business_session.v1`:

```dart
final class StoredBusinessSession {
  const StoredBusinessSession({required this.version, required this.accessToken, required this.refreshToken});
  final int version;
  final String accessToken;
  final String refreshToken;
}
```

Keep recovery-key deletion separate from Business logout. Generate the Matrix SQLCipher key using `Random.secure()` and base64url encoding; never log it.

- [ ] **Step 4: Verify GREEN and commit**

Run the focused test and commit with `feat(mobile): store session pairs atomically`.

### Task 3: Add Business refresh, retry and logout

**Files:**
- Create: `apps/mobile_flutter/test/core/business_api_session_test.dart`
- Modify: `apps/mobile_flutter/lib/core/business_api_client.dart`

- [ ] **Step 1: Write failing HTTP contract tests**

Using a fake `http.Client`, assert that `restoreSession()` posts the stored refresh token to `/api/v1/auth/refresh`, replaces both tokens, classifies connection errors as offline, and clears storage only for authoritative `401`/`403`. Assert `logout()` posts to `/auth/logout` before local cleanup.

```dart
final result = await api.restoreSession();
expect(result, BusinessSessionRestore.authenticated);
expect((await store.session())!.refreshToken, 'rotated-refresh');
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/core/business_api_session_test.dart`

Expected: compilation fails because restore/logout APIs and result enum do not exist.

- [ ] **Step 3: Implement minimum session APIs**

Add `BusinessSessionRestore { absent, authenticated, offline, invalid }`, `restoreSession()`, `refreshSession()` and `logout()`. On authenticated request 401, refresh exactly once and replay exactly once; never retry a financial write unless its original idempotency key is reused.

- [ ] **Step 4: Verify GREEN and commit**

Run focused Business client and existing login-controller tests. Commit with `feat(mobile): restore and revoke business sessions`.

### Task 4: Initialize a persistent SQLCipher Matrix client

**Files:**
- Modify: `apps/mobile_flutter/pubspec.yaml`
- Modify: `apps/mobile_flutter/pubspec.lock`
- Create: `apps/mobile_flutter/lib/features/matrix/matrix_client_factory.dart`
- Create: `apps/mobile_flutter/test/features/matrix/matrix_client_factory_test.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart`

- [ ] **Step 1: Add a failing factory contract test**

Inject path, key and database open callbacks. Assert the factory always uses `liuhetong_matrix.sqlite`, applies a non-empty SQLCipher key before `MatrixSdkDatabase.open()`, calls `Client.init()`, and returns the same persisted client name `liuhetong_mobile`.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/features/matrix/matrix_client_factory_test.dart`

Expected: compilation fails because the factory and initialization methods do not exist.

- [ ] **Step 3: Add pinned compatible dependencies**

Add direct dependencies for `path_provider`, `sqflite`, and `sqlcipher_flutter_libs`; run `flutter pub get` and retain resolved explicit versions in `pubspec.lock`.

- [ ] **Step 4: Implement the factory**

Use `getApplicationSupportDirectory()`, `SQfLiteEncryptionHelper`, `MatrixSdkDatabase`, and the secure-store database key. Call `ensureDatabaseFileEncrypted()`, open with `onConfigure: helper.applyPragmaKey`, construct `Client(databaseBuilder: ...)`, then `await client.init()`.

Extend `MatrixE2eeClient` with `isLoggedIn`, `userId`, `deviceId`, `logout()` and typed sync/session-invalid classification. Do not expose recovery keys to Business code.

- [ ] **Step 5: Verify GREEN and commit**

Run the factory and existing Matrix tests, `flutter analyze`, then commit with `feat(matrix): persist encrypted mobile sessions`.

### Task 5: Implement the dual-domain startup state machine

**Files:**
- Create: `apps/mobile_flutter/lib/core/session_bootstrap_controller.dart`
- Create: `apps/mobile_flutter/test/core/session_bootstrap_controller_test.dart`

- [ ] **Step 1: Write failing state-machine tests**

Cover no session, both domains restored, offline Business with persisted Matrix session, invalid Refresh Token, Matrix unknown token, mismatched Business/Matrix identity, and local database fatal error.

```dart
await controller.bootstrap();
expect(controller.state.status, SessionBootstrapStatus.offlineAuthenticated);
expect(fakeStore.clearCalls, 0);
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/core/session_bootstrap_controller_test.dart`

Expected: compilation fails because controller/status types do not exist.

- [ ] **Step 3: Implement minimum transitions**

The controller must produce only `loading`, `authenticated`, `offlineAuthenticated`, `unauthenticated`, or `fatalError`. It clears state only for authoritative invalidation and requires Business user identity to match the Matrix MXID localpart mapping.

- [ ] **Step 4: Verify GREEN and commit**

Run the focused test and commit with `feat(auth): coordinate persistent dual sessions`.

### Task 6: Route startup and explicit logout UI

**Files:**
- Create: `apps/mobile_flutter/lib/session_gate.dart`
- Modify: `apps/mobile_flutter/lib/main.dart`
- Modify: `apps/mobile_flutter/lib/app_home.dart`
- Modify: `apps/mobile_flutter/test/widget_test.dart`

- [ ] **Step 1: Write failing widget tests**

Assert loading never flashes the login form, authenticated goes directly to the four-tab home, offline authenticated shows a reconnect banner, invalid session shows login, and confirmed logout clears the navigator stack.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/widget_test.dart`

Expected: tests fail because the app root always renders `LoginPage` and Profile has no logout control.

- [ ] **Step 3: Implement the composition root and gate**

Make `main()` async, initialize bindings and Matrix before `runApp`. `SessionGate` listens to `SessionBootstrapController`; successful login calls `bootstrap()` rather than pushing an independent route. Add “我 → 设置 → 退出登录” with Cupertino confirmation and a callback that revokes/clears both domains.

- [ ] **Step 4: Verify GREEN and commit**

Run widget tests, all Flutter tests and analyze. Commit with `feat(mobile): restore sessions at app startup`.

### Task 7: Reviews, real emulator regression and evidence

**Files:**
- Create: `docs/verification/2026-08-14-mobile-dual-session-persistence.md`
- Modify only if drift exists: `packages/api-contracts/openapi/liuhetong-v1.yaml`

- [ ] **Step 1: Run specification-compliance review**

Check every requirement in the approved spec against implementation and record pass/fail evidence, especially offline retention, active-user refresh validation and dual-user matching.

- [ ] **Step 2: Run Quality/Security review**

Verify the database header is not `SQLite format 3`, SQLCipher opens with the secure key, logs contain no tokens/keys/passwords, logout deletes local session material, and E2EE boundaries are unchanged.

- [ ] **Step 3: Run repository verification**

Run:

```powershell
flutter analyze
flutter test
py -3.12 -m pytest tests/business_api/identity/test_tokens_and_recovery.py -q
pwsh -NoProfile -File scripts/verify.ps1
flutter build apk --release
```

Expected: all commands exit 0; the signed APK includes `android.permission.INTERNET`.

- [ ] **Step 4: Execute two-emulator acceptance**

Install the same configured Release APK on `emulator-5554` and `emulator-5556`. Log in as `liuhetong_test01`/`liuhetong_test02`, force-stop both apps, relaunch, assert both open the home tabs without credentials, then send/accept a friend request and confirm both contact lists contain the peer.

- [ ] **Step 5: Record evidence and commit**

Record commands, statuses, device IDs before/after restart, and UI assertions without tokens or passwords. Commit with `test(auth): verify persistent dual sessions`.

