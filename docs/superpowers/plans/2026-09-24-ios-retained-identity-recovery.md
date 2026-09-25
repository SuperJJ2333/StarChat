# iOS Retained Identity Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop iOS from initializing a replacement Olm identity before continuity validation, then let an authenticated user explicitly keep the old encrypted store and log in as a new Matrix device when the old identity cannot be used.

**Architecture:** A read-only local probe runs before SDK initialization and before switching to a retained account. A durable archive transaction moves only the account's active scope pointer to a fresh store; old database files and Keychain material remain at their original scope. Login, retained-session bootstrap, and cold startup expose the same typed recovery state; the business-authorized MXID and homeserver are checked again before the transaction and after broker login.

**Tech Stack:** Flutter/Dart, vendored Matrix SDK, `olm` 2.0.4, iOS SQLCipher via `sqflite_common_ffi`, iOS Keychain bridge, Flutter tests, GitHub macOS CI, enterprise IPA verifier.

---

## Source map and ownership

- `apps/mobile_flutter/lib/features/matrix/local_identity_preflight.dart`: typed causes and strictly read-only SQLCipher/Olm probe. Owns no UI or storage mutation.
- `apps/mobile_flutter/lib/core/session_store.dart`: read-only scope snapshots, archive index, durable transaction journal, crash replay. It alone mutates registry and active pointer.
- `apps/mobile_flutter/lib/features/matrix/matrix_client_factory.dart`: invokes the probe before key creation/SDK initialization and before account selection; coordinates confirmed archive transaction.
- `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart`: serializes confirmed recovery with old-client suspension, scope transition, and fresh-client resume.
- `apps/mobile_flutter/lib/features/auth/login_controller.dart`: preserves typed recovery state through business login and consumes a fresh broker grant on confirmation.
- `apps/mobile_flutter/lib/features/auth/login_page.dart`, `authentication_flow.dart`: explicit warning, cancel, and confirm for password and phone login.
- `apps/mobile_flutter/lib/main.dart`, `core/session_bootstrap_controller.dart`, `session_gate.dart`: safe cold-start composition without opening the unverified DB, and retained-session recovery action.
- `apps/mobile_flutter/pubspec.yaml`, `pubspec.lock`: direct `olm: 2.0.4` dependency matching the existing lock.
- `apps/mobile_flutter/ios/Runner/IOSSecureSession.swift`, `IOSSecureSessionBridge.swift`, `ios/RunnerTests/RunnerTests.swift`: native `peek` that performs only `SecItemCopyMatching` during preflight, including old-accessibility items.
- `apps/mobile_flutter/lib/core/installation_container_probe.dart`, `test/core/installation_container_probe_test.dart`: recognize orphaned SQLCipher WAL/SHM as surviving installation data before any Keychain cleanup.
- `apps/mobile_flutter/test/features/matrix/local_identity_preflight_test.dart`, `test/core/session_store_test.dart`, `test/features/matrix/matrix_client_factory_test.dart`, `test/features/auth/login_controller_test.dart`, `test/core/session_bootstrap_controller_test.dart`, `test/features/auth/login_page_test.dart`: focused red/green evidence.
- `.github/workflows/ios-testflight.yml`, mobile version metadata and release tests: 0.4.7 build greater than 2172 with in-app enterprise update enabled; exact build selected after current-version inventory.
- `docs/verification/2026-09-24-ios2144-old-account-l07.md` and task ledger: commands, exit codes, SHA identity, real-device outcomes, and unresolved limits.

Agents must not edit the same file at once. Core preflight and archive work are sequential in `session_store.dart`/factory; auth adapter and UI can run beside them against the agreed interfaces; root owns bootstrap/main/release and docs.

### Task 1: Read-only identity probe and pre-init guard

**Files:** `local_identity_preflight.dart`, `session_store.dart`, `matrix_client_factory.dart`, `pubspec.yaml`, `pubspec.lock`, focused matrix tests.

- [ ] Write a failing fixture with an existing encrypted DB and binding whose saved fingerprint differs from the unpickled Olm account. Assert `MatrixClientFactory.create()` throws `MatrixLocalIdentityPreflightException(fingerprintMismatch)` and the injected opener, key generator, migrator, and network uploader each receive zero calls.
- [ ] Run `flutter test test/features/matrix/local_identity_preflight_test.dart test/features/matrix/matrix_client_factory_test.dart`; capture the expected test failure and exit code in verification evidence.
- [ ] Add `olm: 2.0.4` directly to `pubspec.yaml` and regenerate the lock with `flutter pub get`. Define `MatrixLocalIdentityCause` with `missingDatabaseWithBinding`, `missingKey`, `missingOlmAccount`, `fingerprintMismatch`, `identityMismatch`, `unreadable`; never include cipher/pickle in exception text.
- [ ] Add failing native Keychain tests using a fake `IOSSessionSecurityOperations`: reading an item with old accessibility through the new `peek` returns its value, while update/add/delete call counts remain zero. Add `IOSSecureSessionStore.peek(key:)` using `lookup` and UTF-8 decode only; expose bridge method `peek`; route Dart preflight snapshots through this method on iOS. Keep existing `read` migration behavior for normal application reads.
- [ ] Implement a probe that opens an existing SQLCipher file in **actual read-only mode**, applies the existing key, queries `box_client` for `user_id` and `olm_account`, unpickles with the stored user ID, reads Ed25519, frees the Olm object, and closes the DB. No `matrixDatabaseKey()`, `ensureDatabaseFileEncrypted()`, `MatrixSdkDatabase.open()`, or `Client.init()` in this path. Distinguish no DB/no binding (pristine) from any retained or uncertain state.
- [ ] Expose read-only active/target snapshots from `SecureSessionStore`; in factory `create()` run probe before `matrixDatabaseKey()` or opener, and in `selectAccount()` run probe before `selectMatrixAccount()` writes registry/active. Allow a true pristine account to use the existing first-login path. Inspect registered, legacy and fixed-name local candidate stores; `canCreateNewDevice` is true only after all candidates are readable and no original identity matches. A unique original or ambiguous/unreadable candidates block new-device creation in this release.
- [ ] Make mismatch/missing-pickle/missing-key/unreadable tests green; assert DB bytes and old binding/key strings are unchanged. Add a test where preflight reads a legacy homeserver in the DB but binding/account expected homeserver and MXID match, so the existing later migrator remains possible.
- [ ] Verify SQLCipher read-only open and WAL visibility in a macOS/iOS native test. If the FFI library cannot read without creating files, keep the failure closed and adjust the probe before release; a Dart fake-only test is insufficient.
- [ ] Commit only these core changes after focused tests and analysis pass; retain the red/green command evidence.

### Task 2: Durable archive and fresh-device storage transaction

**Files:** `session_store.dart`, `matrix_client_factory.dart`, `installation_container_probe.dart`, `test/core/session_store_test.dart`, `test/core/installation_container_probe_test.dart`, `test/core/installation_reconciler_test.dart`, `test/features/matrix/matrix_client_factory_test.dart`.

- [ ] Write failing tests for a retained account A whose old scope contains DB key, binding and recovery key: confirmed rotation yields a different 64-hex scope/key; old scoped items and `liuhetong_matrix_<old>.sqlite` (plus WAL/SHM) remain byte-for-byte unchanged; account B is unaffected; A→B→A selects the new A scope.
- [ ] Write failure-injection tests after journal write, new key write, registry write, and active-scope write. Recreating `SecureSessionStore` and replaying the journal must select exactly one known state: old pointer with old data intact, or committed new pointer with old archive intact. Unknown journal/registry combinations throw without SDK initialization.
- [ ] Write additional failure-injection tests before and after archive-index write, after commit marker, and during journal deletion. At every restart, old scope must remain in a verified archive index or live journal; never let a half-committed registry/active pointer orphan it.
- [ ] Implement a fixed-version unscoped Keychain archive index keyed by hashed `(homeserver, MXID, generation)` and a journal containing old/new scopes, expected account hash, phase, and file/key references only. Write journal and index, then read back/verify index **before** new key, registry or active pointer; delete journal last. Preserve old key/binding/recovery key; protect archive scopes from ordinary current-slot clear. Make `clearInstallation()` enumerate archive scopes and delete their scoped secrets/index/journal only when installation reconciliation proves no old DB or WAL/SHM remains; if deletion fails keep an enumeration entry for the next retry.
- [ ] In `FileSystemInstallationContainerProbe`, recognize `.sqlite`, `.sqlite.encrypted`, `-wal` and `-shm` even if the main DB has disappeared. Run the focused probe test red first, then green; retain the fail-closed rule when directory enumeration errors.
- [ ] Add an uninstall/reinstall simulation with archived old scope: any old DB or sidecar prevents installation clear, while a genuinely empty new container clears old archived Keychain items. Inject a delete failure and assert the next launch can retry without losing archive enumeration.
- [ ] `prepareFreshDeviceForConfirmedRecovery(expectedHomeserver, expectedUserId)` must re-run the read-only probe and confirm the exact Business-authorized target; reject unreadable/ambiguous states, and return the same new scope if the already committed transaction is retried. Close old client/DB before writing journal; write fresh key, registry, active pointer, then commit marker before SDK opens the new DB.
- [ ] If inventory finds a unique, fully verified original identity in another registered/legacy slot, expose `adoptVerifiedOriginalCandidate` using the same journal and Business target check. It changes pointers only after closing the old client and never copies or rewrites the candidate database/key/binding. Test crash replay and old-chat access. Do not offer new-device confirmation for this state until the original-identity recovery path has been attempted or expressly declined.
- [ ] Run the focused tests including concurrent confirmation and crash replay; assert zero writes to the old DB and no old device ID passed to login. Commit after green.

### Task 3: Explicit authorization and login UI

**Files:** `matrix_e2ee_client.dart`, `login_controller.dart`, `authentication_flow.dart`, `login_page.dart`, related focused tests.

- [ ] Write failing tests: a typed preflight exception after Business authentication leaves the Business session intact, does not call `_compensate`/clear, and surfaces `recoveryRequired` to password and phone login; cancel leaves scope, DB, Keychain and session unchanged.
- [ ] Add a separate dialog with the concrete warning “旧聊天记录可能无法解密，原有本机聊天数据将保留” and a note that another device may be logged out under the single-device policy. Use explicit “取消” and “保留旧库并建立新设备” actions; no automatic confirmation and no reuse of the destructive account-switch dialog.
- [ ] Have `MatrixSdkE2eeClient` queue recovery in the existing serialized lifecycle: suspend and dispose old client, invoke factory's confirmed archive callback, select the new account scope, resume a pristine client. The auth service obtains a **new** broker grant after confirmation, checks grant MXID/homeserver against the authenticated Business identity, calls token login without old device ID, checks returned user ID, then binds/completes/syncs.
- [ ] Test wrong grant MXID, wrong homeserver, network expiry, repeated taps, account switch, and server rejection. All must keep the old archive untouched; failed new-device login may be retried against the same new scope without allocating another scope.
- [ ] Run affected auth/widget tests and `flutter analyze`; commit after green.

### Task 4: Cold startup and retained Business session

**Files:** `main.dart`, `core/session_bootstrap_controller.dart`, `session_gate.dart`, focused bootstrap and startup/widget tests.

- [ ] Write failing startup test: when `matrixFactory.create()` returns a typed recoverable preflight failure, app composition must not enter the generic infinite “重试” page, must not initialize the old DB, and must not display cached chats before Business authentication.
- [ ] On a recoverable preflight failure, compose only an uninitialized in-memory Matrix client for the authentication shell. Keep unreadable/unknown states on a retry-only failure screen. Let `SessionBootstrapController` preserve a typed `recoveryRequired` state from retained-session restore; `SessionGate` shows the same warning and confirmation only after `BusinessSessionRestore.authenticated` and target MXID/homeserver verification.
- [ ] Wire confirmation to `DualDomainLoginService.confirmNewDeviceAndLogin()` and then rerun bootstrap. A missing/invalid Business session routes to normal login; confirmation before valid Business auth is disabled. Test system back/cancel/retry, app restart during journal replay, and new-account login from this state.
- [ ] Run focused bootstrap/UI tests; commit after green.

### Task 5: Versioned enterprise candidate and verification

**Files:** iOS version metadata, `.github/workflows/ios-testflight.yml`, release metadata tests, runbooks/evidence.

- [ ] Read current production, pending artifacts and CI to choose an unused build number **above 2172**. Keep display name 0.4.7 if available. A previously signed 2172 IPA is never treated as containing this fix.
- [ ] Add a failing release test proving the enterprise candidate has in-app updates enabled; change the appropriate CI build define from `LIUHETONG_IN_APP_UPDATE=false` to `true` for enterprise delivery while keeping App Store policy explicit.
- [ ] Preflight Flutter/Xcode/CI and run focused tests, `flutter analyze`, then `pwsh -NoProfile -File scripts/verify.ps1` only for gates not covered by identical CI evidence. Record every command, exit code, source SHA, lock hash and logs.
- [ ] Build one unsigned/CI-signed iOS candidate on macOS. Verify version/build, Bundle ID, executable/Frameworks manifest, APNs/call capability build settings, SQLCipher presence and update flag. Hand candidate IPA and SHA to the user for the existing enterprise signer; do not distribute an unsigned or unverified candidate.
- [ ] After the user returns final signed IPA, run `scripts/verify_ios_enterprise_ipa.py`, compare non-signature content with candidate and the user's established signing service additions, confirm signed App ID/Team/Keychain group/production APNs, and bind the final SHA to a healthy 2144 no-uninstall cover test. An affected phone with preexisting L07 cannot prove old chat retention.
- [ ] Only after signed-IPA and true cover data evidence, use the production runbook to publish iOS package, manifest, download page and update setting atomically by stage; verify HTTPS, manifest XML/MIME, platform isolation, audit and rollback. Keep 2172 disabled if any gate fails.

## Final checks

- [ ] Review the implementation against every paragraph of ADR-0086 and the design; Domain review first, Quality/Security review second.
- [ ] Confirm no test or implementation writes Olm/SQLCipher/key material to logs or server and no automatic clear/rebind path was introduced.
- [ ] Update the task ledger and verification evidence with exact build/SHA, outcomes, user signing handoff and next executable step.

The user's explicit acceptance covers the new-device recovery choice. It does not prove that an already-lost Olm private key can be reconstructed or that a differently signed App ID will preserve the old iOS container.
