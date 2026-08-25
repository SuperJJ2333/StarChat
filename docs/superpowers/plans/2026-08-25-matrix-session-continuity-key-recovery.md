# Matrix Session Continuity and Key Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve a Matrix device and its encrypted local history across ordinary logout/restart, implement real Megolm online backup and trusted-device recovery, expose accurate decryption states, and prove the behavior on a public-connected Android emulator.

**Architecture:** Keep Business authentication separate from a versioned local Matrix binding. A focused recovery service wraps Matrix SSSS, cross-signing, room-key backup, and standard encrypted device-secret/key requests; a separate observable controller owns per-event decryption state. Destructive local reset is available only through confirmed account switching or an explicit clear-chat-data command.

**Tech Stack:** Flutter/Dart, matrix 0.34.0, SQLCipher/sqflite, flutter_secure_storage, Matrix SSSS/cross-signing/Megolm room-key backup, Synapse Docker, Flutter integration_test, PowerShell 7, Android ADB.

---

## File map and ownership

New focused files:

- `apps/mobile_flutter/lib/core/matrix_local_binding.dart`: versioned MXID/device/database-generation model only.
- `apps/mobile_flutter/lib/features/matrix/matrix_recovery_service.dart`: backup bootstrap, online restore, trusted-device secret and room-session request orchestration.
- `apps/mobile_flutter/lib/features/matrix/decryption_state_controller.dart`: observable per-event state machine and retry policy.
- `apps/mobile_flutter/lib/features/matrix/e2ee_diagnostics.dart`: stable event codes and HMAC-redacted structured diagnostics.
- `apps/mobile_flutter/test/features/matrix/matrix_recovery_service_test.dart`: backup and trust policy unit tests.
- `apps/mobile_flutter/test/features/matrix/decryption_state_controller_test.dart`: deterministic state/timeout tests.
- `apps/mobile_flutter/test/features/matrix/e2ee_diagnostics_test.dart`: secret-redaction tests.
- `apps/mobile_flutter/integration_test/matrix_session_continuity_test.dart`: app lifecycle regression driver.
- `scripts/test_matrix_session_continuity.ps1`: local/public emulator orchestration and evidence capture.
- `docs/verification/2026-08-25-matrix-session-continuity-key-recovery.md`: final verification and deployment record.
- `docs/verification/2026-08-25-matrix-session-continuity-domain-review.md`: protected Domain Review.
- `docs/verification/2026-08-25-matrix-session-continuity-quality-security-review.md`: protected Quality/Security Review.

Existing files with bounded changes:

- `apps/mobile_flutter/lib/core/session_store.dart`: persist/delete the binding, recovery key, and diagnostic salt independently.
- `apps/mobile_flutter/lib/core/session_bootstrap_controller.dart`: preserve a locally logged Matrix domain when Business auth is absent/invalid.
- `apps/mobile_flutter/lib/features/auth/login_controller.dart`: compare binding before token exchange and reuse/re-authenticate the same device.
- `apps/mobile_flutter/lib/features/matrix/matrix_client_factory.dart`: expose explicit preserve/reopen and confirmed destructive reset paths.
- `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart`: SDK adapter for same-device reauthentication, backup, restore, requests, and clear.
- `apps/mobile_flutter/lib/features/matrix/conversation_presentation.dart`: map the observable decryption state to approved text.
- `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`: consume state without starting asynchronous work from `build()`.
- `apps/mobile_flutter/lib/features/matrix/matrix_security_page.dart`: backup status, optional recovery-key export/import, and explicit local-clear entry.
- `apps/mobile_flutter/lib/main.dart`: construct and inject binding/recovery/decryption services.
- `apps/mobile_flutter/pubspec.yaml`: add SDK `integration_test` development dependency.
- `scripts/verify.ps1`: run the new non-network Flutter focused suites; live Synapse/ADB checks remain explicit release gates.
- `docs/adr/0007-mobile-matrix-session-continuity-and-key-recovery.md`: mark approved only after both reviews pass.

No Business API schema, endpoint, migration, or OpenAPI change is planned. No server component may receive a plaintext recovery or room key.

### Task 1: Complete protected pre-implementation reviews

**Files:**
- Create: `docs/verification/2026-08-25-matrix-session-continuity-domain-review.md`
- Create: `docs/verification/2026-08-25-matrix-session-continuity-quality-security-review.md`
- Modify: `docs/adr/0007-mobile-matrix-session-continuity-and-key-recovery.md`

- [ ] **Step 1: Write the Domain Review against concrete invariants**

Record PASS/FAIL for this exact matrix:

```markdown
| Invariant | Required conclusion |
|---|---|
| Business authority | Business API authenticates; it never transports Matrix secrets |
| Same-account binding | Login grant MXID must equal preserved binding before chat opens |
| Different account | Reset occurs only after explicit confirmation |
| Ordinary logout | Business session clears; Matrix DB/device/keys remain |
| Invalid token/ban | Access is denied without deleting Matrix data |
| Financial boundary | No Matrix event or key state mutates ledger/wallet state |
```

- [ ] **Step 2: Write the Quality/Security Review threat matrix**

Record attacker, control, assertion, and result for stolen Business Token, stolen Matrix Token, unverified device, blocked device, forged request ID, replay after 15 minutes, mismatched backup public key, corrupted SQLCipher DB, rooted-device limitation, and sensitive-log leakage.

- [ ] **Step 3: Verify both reviews approve without exceptions**

Run:

```powershell
rg -n "FAIL|BLOCKED|UNRESOLVED" docs/verification/2026-08-25-matrix-session-continuity-*-review.md
```

Expected: no matches. If a review fails, stop implementation and revise the design/ADR instead of adding a bypass.

- [ ] **Step 4: Mark ADR-0007 approved**

Change only the status line to:

```markdown
**状态：** 已批准（Product、Domain、Quality/Security）
```

- [ ] **Step 5: Commit the protected reviews**

```powershell
git add -- docs/adr/0007-mobile-matrix-session-continuity-and-key-recovery.md docs/verification/2026-08-25-matrix-session-continuity-domain-review.md docs/verification/2026-08-25-matrix-session-continuity-quality-security-review.md
git commit -m "docs(e2ee): approve session continuity security boundaries"
```

### Task 2: Persist a Matrix binding independently of Business auth

**Files:**
- Create: `apps/mobile_flutter/lib/core/matrix_local_binding.dart`
- Modify: `apps/mobile_flutter/lib/core/session_store.dart`
- Modify: `apps/mobile_flutter/test/core/session_store_test.dart`

- [ ] **Step 1: Write failing binding persistence tests**

Add tests that save `@alice:matrix.localhost`, `ALICEDEVICE`, homeserver, and generation; clear Business auth; then assert the binding, Matrix database key, encrypted recovery key, and diagnostic salt remain. Add a second test asserting `clearMatrixIdentity()` removes all four but does not recreate them until requested.

Use this public model:

```dart
final class MatrixLocalBinding {
  const MatrixLocalBinding({
    required this.version,
    required this.matrixUserId,
    required this.deviceId,
    required this.homeserver,
    required this.databaseGeneration,
  });

  final int version;
  final String matrixUserId;
  final String deviceId;
  final String homeserver;
  final String databaseGeneration;
}
```

- [ ] **Step 2: Run the tests and confirm the intended failure**

```powershell
Push-Location apps/mobile_flutter
& C:\src\flutter\bin\flutter.bat test test/core/session_store_test.dart
Pop-Location
```

Expected: FAIL because binding/diagnostic-salt APIs do not exist.

- [ ] **Step 3: Implement versioned storage and narrowly scoped deletion**

Add these APIs to `SecureSessionStore`:

```dart
Future<void> saveMatrixBinding(MatrixLocalBinding binding);
Future<MatrixLocalBinding?> matrixBinding();
Future<String> diagnosticSalt();
Future<void> clearMatrixIdentity();
```

`clearBusinessSession()` must delete only the Business record. `clearMatrixIdentity()` must delete binding, Matrix database key, encrypted recovery key, and diagnostic salt. Reject malformed/unsupported binding JSON with `FormatException`; never silently replace it.

- [ ] **Step 4: Run binding tests green**

Run the Step 2 command. Expected: all `session_store_test.dart` tests PASS.

- [ ] **Step 5: Commit**

```powershell
git add -- apps/mobile_flutter/lib/core/matrix_local_binding.dart apps/mobile_flutter/lib/core/session_store.dart apps/mobile_flutter/test/core/session_store_test.dart
git commit -m "feat(e2ee): persist matrix binding across business logout"
```

### Task 3: Preserve Matrix state during bootstrap and ordinary logout

**Files:**
- Modify: `apps/mobile_flutter/lib/core/session_bootstrap_controller.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart`
- Modify: `apps/mobile_flutter/test/core/session_bootstrap_controller_test.dart`

- [ ] **Step 1: Replace destructive expectations with failing preservation tests**

Add/adjust tests for Business restore `absent` and `invalid` while Matrix is locally logged in. Both must become unauthenticated, call `suspend()` once, and keep `resetCalls == 0`. Add `M_UNKNOWN_TOKEN` sync coverage asserting Business logout plus Matrix suspension, never reset.

The gateway contract must separate these commands:

```dart
abstract interface class MatrixSessionGateway {
  bool get isLoggedIn;
  String? get userId;
  String? get deviceId;
  Future<void> sync();
  Future<void> suspend();
  Future<void> clearLocalChatData();
}
```

- [ ] **Step 2: Run focused red tests**

```powershell
Push-Location apps/mobile_flutter
& C:\src\flutter\bin\flutter.bat test test/core/session_bootstrap_controller_test.dart
Pop-Location
```

Expected: existing invalid-session tests fail because they call reset.

- [ ] **Step 3: Implement non-destructive bootstrap transitions**

For absent/invalid Business auth, call `_bestEffortMatrixSuspend()` when Matrix state exists, then expose unauthenticated UI. For `M_UNKNOWN_TOKEN`/`M_FORBIDDEN`, clear Business auth, suspend Matrix, preserve local data, and show “登录状态已失效，请重新登录”. Remove generic reset from bootstrap error compensation.

- [ ] **Step 4: Run focused tests green**

Run Step 2. Expected: PASS and every ordinary logout/invalid-token assertion has `resetCalls == 0`.

- [ ] **Step 5: Commit**

```powershell
git add -- apps/mobile_flutter/lib/core/session_bootstrap_controller.dart apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart apps/mobile_flutter/test/core/session_bootstrap_controller_test.dart
git commit -m "fix(e2ee): preserve matrix store across logout and restart"
```

### Task 4: Reuse or reauthenticate the bound Matrix device on login

**Files:**
- Modify: `apps/mobile_flutter/lib/features/auth/login_controller.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_client_factory.dart`
- Modify: `apps/mobile_flutter/test/features/auth/login_controller_test.dart`
- Modify: `apps/mobile_flutter/test/features/matrix/matrix_client_factory_test.dart`

- [ ] **Step 1: Write failing same/different-account tests**

Define a decision result instead of resetting inside login:

```dart
enum MatrixIdentityDecision { firstLogin, reuse, reauthenticate, switchRequired }

final class MatrixAccountSwitchRequired implements Exception {
  const MatrixAccountSwitchRequired({
    required this.fromMxid,
    required this.toMxid,
  });
  final String fromMxid;
  final String toMxid;
}

abstract interface class MatrixTokenLoginGateway {
  bool get isLoggedIn;
  String? get userId;
  String? get deviceId;
  Future<void> loginWithToken({required String loginToken, required Uri homeserver, String? deviceId});
  Future<void> sync();
  Future<void> suspend();
  Future<void> clearLocalChatData();
}
```

Assert: same logged identity does not consume the Login Token; soft-logged same identity calls token login with the preserved device ID; different MXID throws a typed `MatrixAccountSwitchRequired` and does not clear until the caller confirms; network/sync failure preserves Matrix data.

- [ ] **Step 2: Run focused tests red**

```powershell
Push-Location apps/mobile_flutter
& C:\src\flutter\bin\flutter.bat test test/features/auth/login_controller_test.dart test/features/matrix/matrix_client_factory_test.dart
Pop-Location
```

Expected: FAIL on current eager reset and cleanup logout behavior.

- [ ] **Step 3: Implement same-device token login**

Pass `deviceId:` to Matrix `Client.login('m.login.token', ...)`. Permit this only when the preserved binding MXID matches the grant MXID. For SDK soft logout, update authentication using the existing device ID and database; never call SDK `logout()` because it calls `clear()`.

Change every login failure compensation to suspend Matrix and preserve its database, including a partially initialized first-login database. Return `MatrixAccountSwitchRequired` to the UI before destructive work. If the user cancels the switch prompt, clear the newly authenticated Business session so account B cannot coexist with account A's preserved Matrix state.

- [ ] **Step 4: Implement explicit confirmed switch**

Expose:

```dart
Future<void> confirmAccountSwitchAndLogin();
```

After confirmation it requests a fresh Login Token, verifies that its MXID still equals the proposed target, calls `clearLocalChatData()` exactly once, creates a new client/database generation, logs in without the old device ID, syncs, then saves the new binding only after MXID/device validation succeeds. A changed target or token failure stops before deletion.

- [ ] **Step 5: Run focused tests green**

Run Step 2. Expected: PASS, including no reset for same identity and one clear for a confirmed different identity.

- [ ] **Step 6: Commit**

```powershell
git add -- apps/mobile_flutter/lib/features/auth/login_controller.dart apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart apps/mobile_flutter/lib/features/matrix/matrix_client_factory.dart apps/mobile_flutter/test/features/auth/login_controller_test.dart apps/mobile_flutter/test/features/matrix/matrix_client_factory_test.dart
git commit -m "feat(e2ee): reauthenticate the preserved matrix device"
```

### Task 5: Implement real Megolm backup and online restore

**Files:**
- Create: `apps/mobile_flutter/lib/features/matrix/matrix_recovery_service.dart`
- Create: `apps/mobile_flutter/test/features/matrix/matrix_recovery_service_test.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart`
- Modify: `apps/mobile_flutter/lib/main.dart`

- [ ] **Step 1: Write failing backup coordinator tests**

Define an adapter with these explicit operations so unit tests do not need live Synapse:

```dart
abstract interface class MatrixRecoveryBackend {
  String get matrixUserId;
  String get deviceId;
  Future<RecoveryBootstrapResult> bootstrapOnlineBackup({String? recoveryKey});
  Future<void> uploadPendingInboundSessions();
  Future<void> unlockSecretStorage(String recoveryKey);
  Future<void> restoreAllInboundSessions();
  Future<bool> backupKeyMatchesCurrentVersion();
}

enum RecoveryBootstrapResult {
  created,
  reused,
  needsSecretStorageUnlock,
  needsInteractiveAuthentication,
}
```

Test first configuration, existing valid SSSS, existing backup preservation, idempotent upload retry, invalid recovery key, public-key mismatch, partial restore, and proof that no recovery operation invokes a Business gateway.

- [ ] **Step 2: Run red tests**

```powershell
Push-Location apps/mobile_flutter
& C:\src\flutter\bin\flutter.bat test test/features/matrix/matrix_recovery_service_test.dart
Pop-Location
```

Expected: FAIL because recovery types/service do not exist.

- [ ] **Step 3: Implement SDK Bootstrap state handling without automatic wipes**

Use `Bootstrap(encryption: client.encryption!)`. Handle only safe transitions with an exhaustive statement:

```dart
switch (bootstrap.state) {
  case BootstrapState.askNewSsss:
    await bootstrap.newSsss();
  case BootstrapState.askUseExistingSsss:
    bootstrap.useExistingSsss(true);
  case BootstrapState.askWipeCrossSigning:
    await bootstrap.wipeCrossSigning(false);
  case BootstrapState.askSetupCrossSigning:
    await bootstrap.askSetupCrossSigning(
      setupMasterKey: true,
      setupSelfSigningKey: true,
      setupUserSigningKey: true,
    );
  case BootstrapState.askWipeOnlineKeyBackup:
    bootstrap.wipeOnlineKeyBackup(false);
  case BootstrapState.askSetupOnlineKeyBackup:
    await bootstrap.askSetupOnlineKeyBackup(true);
  case BootstrapState.done:
    return;
  case BootstrapState.askWipeSsss:
  case BootstrapState.askUnlockSsss:
  case BootstrapState.askBadSsss:
  case BootstrapState.openExistingSsss:
  case BootstrapState.loading:
  case BootstrapState.error:
    throw RecoveryNeedsUserAction(bootstrap.state);
}
```

Define the actionable exception in the same file:

```dart
final class RecoveryNeedsUserAction implements Exception {
  const RecoveryNeedsUserAction(this.state);
  final BootstrapState state;
}
```

For `askWipeSsss`, `askBadSsss`, UIA, or `error`, return a typed actionable state; never wipe automatically. After a new SSSS key is created, persist `newSsssKey.recoveryKey` through `SecureSessionStore.saveEncryptedRecoveryKey()`.

- [ ] **Step 4: Implement actual restore and incremental upload**

Open/unlock the default SSSS key, call `maybeCacheAll()`, validate `m.megolm_backup.v1` against the current backup public key, then call `keyManager.loadAllKeys()`. After sync, call `keyManager.uploadInboundGroupSessions(skipIfInProgress: true)`.

- [ ] **Step 5: Run recovery tests green**

Run Step 2. Expected: PASS, including “existing backup is never wiped automatically”.

- [ ] **Step 6: Commit**

```powershell
git add -- apps/mobile_flutter/lib/features/matrix/matrix_recovery_service.dart apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart apps/mobile_flutter/lib/main.dart apps/mobile_flutter/test/features/matrix/matrix_recovery_service_test.dart
git commit -m "feat(e2ee): add encrypted megolm backup and restore"
```

### Task 6: Add trusted-device secret and session-key recovery

**Files:**
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_recovery_service.dart`
- Modify: `apps/mobile_flutter/test/features/matrix/matrix_recovery_service_test.dart`

- [ ] **Step 1: Write failing trust-policy tests**

Inject `DateTime Function() now` and `Future<void> Function(Duration) delay` without adding a runtime timing dependency. Assert requests target only same-user verified unblocked devices; reject wrong user, current device, unverified, blocked, wrong request ID, wrong sender Curve25519 key, unencrypted response, expired response, and backup-public-key mismatch.

Test both recovery levels:

```dart
Future<TrustedRecoveryResult> requestBackupSecret();
Future<TrustedRecoveryResult> requestRoomSession({
  required String roomId,
  required String sessionId,
  required String senderKey,
});

enum TrustedRecoveryResult {
  restored,
  noTrustedDevice,
  timedOut,
  rejected,
}
```

- [ ] **Step 2: Run trust tests red**

Run the Task 5 Step 2 command. Expected: new trusted-recovery cases FAIL.

- [ ] **Step 3: Implement standard Matrix requests**

For the backup secret, call SSSS `request(megolmKey, verifiedOwnDevices)` and accept only the SDK-validated cached secret associated with the pending request. For a missing room session after online backup returns `M_NOT_FOUND`, send a standard `m.room_key_request` only to verified own devices and register the exact devices in `keyManager.outgoingShareRequests`; accept the Olm-encrypted `m.forwarded_room_key` only through the SDK handler.

Keep Matrix's 15-minute protocol validity, but return a UI timeout after 30 seconds. A later valid response may still transition the event back to recovery.

- [ ] **Step 4: Run trust tests green**

Run the Task 5 Step 2 command. Expected: all backup and trust-policy tests PASS.

- [ ] **Step 5: Commit**

```powershell
git add -- apps/mobile_flutter/lib/features/matrix/matrix_recovery_service.dart apps/mobile_flutter/test/features/matrix/matrix_recovery_service_test.dart
git commit -m "feat(e2ee): recover keys from trusted matrix devices"
```

### Task 7: Add observable decryption states and safe diagnostics

**Files:**
- Create: `apps/mobile_flutter/lib/features/matrix/decryption_state_controller.dart`
- Create: `apps/mobile_flutter/lib/features/matrix/e2ee_diagnostics.dart`
- Create: `apps/mobile_flutter/test/features/matrix/decryption_state_controller_test.dart`
- Create: `apps/mobile_flutter/test/features/matrix/e2ee_diagnostics_test.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/conversation_presentation.dart`
- Modify: `apps/mobile_flutter/test/features/matrix/conversation_presentation_test.dart`

- [ ] **Step 1: Write failing deterministic state tests**

Define:

```dart
enum MessageDecryptionState { decrypting, decrypted, missingKey, failed }

final class DecryptionEntry {
  const DecryptionEntry(this.state, {this.eventCode});
  final MessageDecryptionState state;
  final String? eventCode;
}
```

Test local lookup, online lookup, trusted request, offline waiting, injected 30-second UI timeout, late-key success, retry, corrupted session, and “decrypted never regresses on network failure”.

- [ ] **Step 2: Write failing diagnostic-redaction tests**

Feed a message body, recovery key, session key, Access Token, MXID, room ID, event ID, and device ID into the diagnostic API. Assert none appears in serialized output; assert stable installation-scoped 24-hex-character HMAC identifiers and a shared `trace_id` do appear.

- [ ] **Step 3: Run red tests**

```powershell
Push-Location apps/mobile_flutter
& C:\src\flutter\bin\flutter.bat test test/features/matrix/decryption_state_controller_test.dart test/features/matrix/e2ee_diagnostics_test.dart test/features/matrix/conversation_presentation_test.dart
Pop-Location
```

Expected: FAIL because state/diagnostic types and approved copy do not exist.

- [ ] **Step 4: Implement state controller and presentation mapping**

Map states exactly:

```dart
String decryptionPlaceholder(MessageDecryptionState state) => switch (state) {
  MessageDecryptionState.decrypting => '正在解密',
  MessageDecryptionState.missingKey => '缺少密钥，无法解密',
  MessageDecryptionState.failed => '消息解密失败',
  MessageDecryptionState.decrypted => '',
};
```

Start recovery from controller/timeline events, never from widget `build()`. Notify listeners on each transition and when `Room.onSessionKeyReceived` yields a late key.

- [ ] **Step 5: Implement HMAC diagnostics**

Use HMAC-SHA256 with the installation salt returned by `SecureSessionStore.diagnosticSalt()`, emit the first 12 bytes as lowercase hex, and allowlist only the fields/error codes in the specification. Do not accept an arbitrary details map.

- [ ] **Step 6: Run focused tests green**

Run Step 3. Expected: PASS and no occurrence of `消息尚未解密` remains in production presentation code.

- [ ] **Step 7: Commit**

```powershell
git add -- apps/mobile_flutter/lib/features/matrix/decryption_state_controller.dart apps/mobile_flutter/lib/features/matrix/e2ee_diagnostics.dart apps/mobile_flutter/lib/features/matrix/conversation_presentation.dart apps/mobile_flutter/test/features/matrix/decryption_state_controller_test.dart apps/mobile_flutter/test/features/matrix/e2ee_diagnostics_test.dart apps/mobile_flutter/test/features/matrix/conversation_presentation_test.dart
git commit -m "feat(e2ee): expose accurate message decryption states"
```

### Task 8: Wire UI, backup controls, account switching, and explicit clear

**Files:**
- Modify: `apps/mobile_flutter/lib/main.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_security_page.dart`
- Modify: `apps/mobile_flutter/lib/app_home.dart`
- Create: `apps/mobile_flutter/test/features/matrix/matrix_security_page_test.dart`
- Modify: `apps/mobile_flutter/test/features/auth/auth_pages_test.dart`
- Modify: `apps/mobile_flutter/test/ui/messaging_surfaces_test.dart`

- [ ] **Step 1: Write failing widget tests**

Assert conversation list and room page update in place through `decrypting → missingKey → decrypting → decrypted`. Assert device-security page shows backup state, retry, optional export/import, and a separate destructive “清除本机聊天数据” row. Assert account-switch and clear dialogs require explicit destructive confirmation; cancellation does not call clear.

- [ ] **Step 2: Run widget tests red**

```powershell
Push-Location apps/mobile_flutter
& C:\src\flutter\bin\flutter.bat test test/features/matrix/matrix_security_page_test.dart test/features/auth/auth_pages_test.dart test/ui/messaging_surfaces_test.dart
Pop-Location
```

Expected: FAIL on missing pages/state injection and current fixed undecrypted copy.

- [ ] **Step 3: Inject shared recovery/decryption controllers**

Construct one session-scoped `MatrixRecoveryService` and `DecryptionStateController` in `main.dart`. Pass them to message list, timeline, and security page. Register listeners in `initState`, remove them in `dispose`, and render state without asynchronous side effects in `build()`.

- [ ] **Step 4: Implement safe backup and recovery UI**

Replace raw exception strings with stable user messages. Show creation/upload/ready/restoring/needs-trusted-device/needs-recovery-key states. Recovery-key export requires device authentication where the platform supports it and an explicit warning; never place the key in logs, clipboard automatically, navigation arguments, or screenshots.

- [ ] **Step 5: Implement confirmed destructive paths**

Ordinary “退出登录” calls `SessionBootstrapController.logout()` only. Account-switch confirmation and “清除本机聊天数据” call `clearLocalChatData()`; cancellation returns without mutation. After local clear, rebuild the Matrix client and navigate to login.

- [ ] **Step 6: Run widget tests green**

Run Step 2. Expected: PASS.

- [ ] **Step 7: Commit**

```powershell
git add -- apps/mobile_flutter/lib/main.dart apps/mobile_flutter/lib/app_home.dart apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart apps/mobile_flutter/lib/features/matrix/matrix_security_page.dart apps/mobile_flutter/test/features/matrix/matrix_security_page_test.dart apps/mobile_flutter/test/features/auth/auth_pages_test.dart apps/mobile_flutter/test/ui/messaging_surfaces_test.dart
git commit -m "feat(e2ee): add recovery status and explicit local clear ui"
```

### Task 9: Add real Synapse integration and lifecycle E2E automation

**Files:**
- Modify: `apps/mobile_flutter/pubspec.yaml`
- Create: `apps/mobile_flutter/integration_test/matrix_session_continuity_test.dart`
- Create: `scripts/test_matrix_session_continuity.ps1`
- Modify: `scripts/verify.ps1`

- [ ] **Step 1: Add the pinned SDK integration test dependency**

```yaml
dev_dependencies:
  integration_test:
    sdk: flutter
```

Run `flutter pub get` and include the generated lockfile change only if dependency resolution changes it.

- [ ] **Step 2: Write the failing integration test driver**

The driver must accept test credentials through `--dart-define`, create/locate an encrypted direct room, wait for a unique encrypted event, verify it decrypts, record device ID and Ed25519 fingerprint in memory, perform ordinary logout, and stop at a deterministic semantics label before process restart. On relaunch/login, it must reopen the same room, verify the event content, and assert the identity values match.

Secrets must be passed through process environment and removed after the run; the test must print only PASS/FAIL, event-code summaries, and hashed identifiers.

- [ ] **Step 3: Write the PowerShell lifecycle orchestrator**

`scripts/test_matrix_session_continuity.ps1` must:

```powershell
param(
    [string]$DeviceId = 'emulator-5554',
    [Parameter(Mandatory)][string]$BusinessBaseUrl,
    [Parameter(Mandatory)][string]$MatrixHomeserver,
    [Parameter(Mandatory)][string]$AliceUsername,
    [Parameter(Mandatory)][securestring]$AlicePassword
)
```

It builds/installs without uninstalling, runs phase one, executes `adb shell am force-stop com.liuhetong.mobile`, relaunches, runs phase two, captures a redacted logcat scan, checks installed APK SHA-256, and writes artifacts only below `docs/verification/artifacts/2026-08-25/matrix-key-recovery/`.

- [ ] **Step 4: Add real online-backup and trusted-device phases**

Use two isolated Matrix clients/databases against Docker Synapse: device A receives/decrypts a Megolm message and uploads backup; device B restores with the test recovery key. Then verify A/B via SAS test hooks, clear only B's fresh test database, request `m.megolm_backup.v1`, and restore again through encrypted `m.secret.send`. Add negative phases for unverified, blocked, tampered, offline, and version-mismatch cases.

- [ ] **Step 5: Run the integration test red before implementation is considered complete**

```powershell
pwsh -NoProfile -File scripts/test_matrix_session_continuity.ps1 -DeviceId emulator-5554 -BusinessBaseUrl https://liuhetong888.com/api/v1 -MatrixHomeserver https://liuhetong888.com -AliceUsername $env:STARCHAT_E2E_ALICE -AlicePassword (ConvertTo-SecureString $env:STARCHAT_E2E_ALICE_PASSWORD -AsPlainText -Force)
```

Expected before all wiring is complete: FAIL at the first missing lifecycle semantics label or backup assertion, without deleting existing emulator app data.

- [ ] **Step 6: Add offline focused suites to repository verification**

Add Flutter commands for binding, bootstrap, login, recovery, trust, state, diagnostics, and security-page tests to `scripts/verify.ps1`. Do not add live credentials or make the full repository gate depend on the public internet.

- [ ] **Step 7: Run integration and repository gates green**

```powershell
pwsh -NoProfile -File scripts/test_matrix_session_continuity.ps1 -DeviceId emulator-5554 -BusinessBaseUrl https://liuhetong888.com/api/v1 -MatrixHomeserver https://liuhetong888.com -AliceUsername $env:STARCHAT_E2E_ALICE -AlicePassword (ConvertTo-SecureString $env:STARCHAT_E2E_ALICE_PASSWORD -AsPlainText -Force)
pwsh -NoProfile -File scripts/verify.ps1
```

Expected: lifecycle, online backup, trusted recovery, negative security matrix, and repository verification all PASS.

- [ ] **Step 8: Commit**

```powershell
git add -- apps/mobile_flutter/pubspec.yaml apps/mobile_flutter/pubspec.lock apps/mobile_flutter/integration_test/matrix_session_continuity_test.dart scripts/test_matrix_session_continuity.ps1 scripts/verify.ps1
git commit -m "test(e2ee): cover logout restart and megolm recovery"
```

### Task 10: Perform post-implementation specification and security reviews

**Files:**
- Modify: `docs/verification/2026-08-25-matrix-session-continuity-domain-review.md`
- Modify: `docs/verification/2026-08-25-matrix-session-continuity-quality-security-review.md`
- Create: `docs/verification/2026-08-25-matrix-session-continuity-key-recovery.md`

- [ ] **Step 1: Run specification-compliance review first**

Trace every requirement in specification sections 2, 4–10, 11.2–11.7, 12, and 13 to a file, test name, and observed result. Any missing trace is FAIL and returns to the relevant implementation task.

- [ ] **Step 2: Run quality/security review second**

Inspect all destructive calls (`logout`, `clear`, database deletion, secure-storage deletion), all secret transfer calls, and every new diagnostic call. Confirm only the two approved destructive entry points reach database deletion and no plaintext secret crosses Business/Synapse/logging boundaries.

- [ ] **Step 3: Run sensitive-data scans**

```powershell
rg -n "recoveryKey|session_key|accessToken|messageContent" docs/verification/artifacts/2026-08-25/matrix-key-recovery
adb -s emulator-5554 logcat -d -v threadtime | Select-String -Pattern 'm.megolm_backup.v1|session_key|recovery|access_token'
```

Expected: no secret values. Field names may occur only in a test allowlist whose values are redacted; document each allowed match.

- [ ] **Step 4: Record final local evidence**

Include exact commands, exit codes, Flutter test counts, Matrix/Synapse test phases, device ID equality as hashes, APK SHA-256, emulator serial, and absence of fatal exceptions. Do not include credentials, recovery keys, room keys, message bodies, or full Matrix identifiers.

- [ ] **Step 5: Commit reviews and evidence**

```powershell
git add -- docs/verification/2026-08-25-matrix-session-continuity-domain-review.md docs/verification/2026-08-25-matrix-session-continuity-quality-security-review.md docs/verification/2026-08-25-matrix-session-continuity-key-recovery.md docs/verification/artifacts/2026-08-25/matrix-key-recovery
git commit -m "docs(e2ee): record key recovery reviews and emulator evidence"
```

### Task 11: Deploy to the public Docker server and re-run public acceptance

**Files:**
- Modify: `docs/verification/2026-08-25-matrix-session-continuity-key-recovery.md`

- [ ] **Step 1: Verify local release candidate immediately before deployment**

```powershell
pwsh -NoProfile -File scripts/verify.ps1
git status --short
git log -1 --oneline
```

Expected: verification PASS; only the known user-owned untracked `docs/verification/artifacts/2026-08-24/moments-release/` may remain.

- [ ] **Step 2: Inspect the public target read-only**

```powershell
ssh -p 23421 root@207.56.8.8 "cd /opt/starchat && docker compose ps && docker compose config --quiet"
```

Expected: current services healthy/config valid. Stop if the target path or compose project differs.

- [ ] **Step 3: Create a recoverable pre-deploy backup**

Create a timestamped source/config archive below `/opt/starchat-backups/` without including runtime databases, signing keys, `.env`, recovery keys, or homeserver secrets in Git or terminal output. Record only archive path and checksum.

- [ ] **Step 4: Synchronize the reviewed source safely**

Transfer an archive built from tracked files at the reviewed commit, extract to a staging directory, verify its manifest, then update `/opt/starchat` while preserving server-owned `.env`, Synapse signing keys, media, databases, and Docker volumes. Never use a broad recursive delete.

- [ ] **Step 5: Rebuild only affected explicitly versioned services**

The change is client-side unless integration inspection proves a pinned Synapse configuration adjustment is required. Run Docker config/health checks; do not rebuild unrelated Business/ledger/wallet services.

- [ ] **Step 6: Publish and verify the APK**

Build the public-domain APK using `scripts/build_mobile_public_domain.ps1`, copy it to `/opt/starchat/releases/mobile/` under a commit-specific filename, calculate local/server SHA-256, and require equality. Cover-install it on `emulator-5554`; never uninstall or run `pm clear` before the continuity test.

- [ ] **Step 7: Run public-connected lifecycle and recovery E2E**

Run `scripts/test_matrix_session_continuity.ps1` against `https://liuhetong888.com`. Require PASS for ordinary logout/restart/same-account decryption, real online backup restore, verified-device recovery, unverified-device refusal, correct missing-key status, and log secret scan.

- [ ] **Step 8: Append deployment evidence and commit**

Record backup path, reviewed commit, container health, APK filename/hash, emulator result, rollback command, and any non-secret limitation. Then:

```powershell
git add -- docs/verification/2026-08-25-matrix-session-continuity-key-recovery.md
git commit -m "docs(deploy): record public e2ee continuity release"
```

## Final execution rule

Do not claim completion if a real Megolm backup version was not created, a room session was not restored on a fresh database, the same-device logout/restart E2E did not pass, either protected review contains an exception, or the public-connected emulator run was not performed. A blocked external credential, emulator, or server condition must be reported with preserved local data; it must never be bypassed by deleting Matrix state or weakening E2EE.
