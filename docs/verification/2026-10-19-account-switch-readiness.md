# Account-switch readiness verification

Last updated 2026-10-19T13:30:59.825791+08:00. Current ordinary Android **0.4.63+2232 Debug** is installed on original emulator-5556 with retained data. Runtime source `2acebfdafcfa7637927913e37a8585dad261b568`. Test/document-only follow-up does not alter the installed runtime. **AS6 real-recipient acceptance remains OPEN.**

## Confirmed findings and changes

Account selection omitted a fresh projection owner; retained login could let an old-token sync401 clear newly adopted credentials. The repair binds the new unverified owner after exact continuity, drains old SDK work before adopting credentials, serializes login intents, and fences stale account/generation callbacks. Only the first persisted retained-login SDK poll uses timeout0; normal backoff and genuine new401 behavior remain.

The Android0.4.52 recipient explicitly reported “the sender has not sent us the session key”. Read-only encrypted-event/public-key metadata confirms server acceptance; acceptance alone does not prove peer decryption. One exact test message was authorized and manually sent by the user after native input inserted nothing; root sent zero additional real messages. Live metadata does not prove the complete historical triggering sequence.

The SDK now requires complete eligible-device ciphertext coverage and every room-key chunk to succeed, checks current owner/member/device context immediately before actual HTTP and after completion, and excludes strict room-key failures from the context-free deferred queue. Eligibility changes use a future-only outbound-session rotation; old inbound history/authorization remains. A separately proven retained-device marker gap is repaired only behind durable exact-credential/identity/owner/database fences. No keys are recreated to bypass identity checks; no plaintext fallback, history authorization expansion or server-side key recovery is added. Already-sent missing-key history is not repaired by this future-send correction.

## Evidence

Evidence root: `artifacts/2026-10-19/account-switch-readiness/` in the interactive-cache-startup worktree. RED, failed attempts and superseded candidates are retained, never relabeled as passing.

| Gate | Actual result | Evidence |
| --- | --- | --- |
| Lifecycle/account-switch focused |153 testDone PASS, exit0 | readiness-green-final |
| Final runtime affected coverage |541 testDone PASS, analyze0; paired version contract3PASS | key-sharing-impact-r3, version contract receipt |
| Final frozen shared command | **FAIL**, analyze0,6367PASS/9SKIP/2FAIL, source stable | final-shared-2232/receipt.json and classification-initial.json |
| Unchanged archive case isolated |1 actual case PASS (+3 harness testDone), exit0 | vault-archive-isolated-original-2232 |
| Corrected complete vault fixture |27 actual cases PASS (+3 harness testDone), exit0; full analyze0 | vault-fixture-green-2232 |
| Protected runtime review | DOMAIN then independent QUALITY PASS | reviews-2232.json |
| Test-only corrective review | DOMAIN then independent QUALITY PASS | fixture-reviews-2232.json |
| Android strict native |9 synthetic cases, driver exit0; original6 audits and new retained-rotation/room-key-roundtrip assertions true | native-2232-r1/receipt.json |
| iOS18 native | seed23PASS; restart verify4PASS | ios-evidence-12160110936.json |
| iOS26 native | seed23PASS; restart verify4PASS | ios-evidence-12159619954.json |
| Complete production iOS unsigned compilation |PASS | run39189028520 full compilation job117857513965 |
| iOS overall CI | **FAIL**; three video-cache host failures also present by name on baseline16905; native phases successful | ios-native-2232-latest.json; ios-host-final-classification-2232.json |

The two final shared failures were a test assumption and its contamination: held outbound work now legitimately has nested admitted writes (2, not exactly1). The boundary test now requires pendingWrites>0 while held, preserving suspension timeout, open database, blocked drain, expected-error and settled-zero assertions. Unconditional teardown releases held SQLite, drains owner work, frees native state and completes suspension even after assertion failure. The unchanged archive case passes alone; the complete corrected file passes without server-mock changes. Original full command remains FAIL.

Only `test/features/matrix/recovery_vault_sdk_test.dart` changed after runtime freeze; fixed-string search found no Dart imports of that test file. Runtime/library/lock/native target/platform inputs remain identical. Per mobile delivery evidence-reuse rules, unaffected full-file results and Android/iOS source-bound gates are reused; the corrected entire file and analyzer were rerun. This is **not** a new all-green full command. Binding receipt: vault-fixture-input-equivalence-2232.json. Latest test SHA `a980923b31f0c9ed792703aba77ea6e34a5c40e8bf3dfa0d3de5e09cab4a3b50`, Olm3.2.15/SQLCipher4.10.0 DLL and lock hashes are in its runner receipt.

Aggregate `scripts/verify.ps1` preflight was NOT_EXECUTED_MISSING_ENV; canonical .env is absent and production credentials were not imported. Windows native input hashes were explicitly verified. Physical iPhone, enterprise signing/retained-data upgrade and actual APNs remain outside these synthetic/unsigned checks. Genuine invalid credentials may still correctly produce authentication failures; no absolute “never L04/L07” claim.

## Installed delivery

Ordinary main Debug APK: `D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-19/account-switch-readiness/main-2232/final.apk`,126130522bytes, SHA256 `bf97af627699e77d58915c020fbec6be90c1c4a85de56f8d8c0492ea96509c1f`, package `com.liuhetong.mobile.debug`, stable signer75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff.

Source→Apktool2.12.1→zipalign36P16→fixed signer→payload/manifest/DEX/ABI verification PASS. Original emulator install-r 2026-10-19T02:34:35.9039828Z→02:34:53.7234724Z PASS; installed byte SHA matches, UID10090 and firstInstall2026-09-26 04:06:20 retained. Diagnostic native APK was replaced by ordinary main. Activity total6311ms is an Android activity metric under test load, not cached-content first paint or a performance improvement measurement.

No production popup/download mutation, new real automatic send, uninstall, data clear or downgrade. Owned wake setting restored0, owned ADB forward removed; no gate/build is still running. Earlier14 ignored synthetic test databases were retained after automatic approval rejected deletion with “blocked by policy”; no retry/workaround and excluded from APK.

## Timing and next action

Frozen shared gate02:13:00Z→02:52:25Z (39m25s), FAIL retained. Strict Android native02:28:54Z→02:34:07Z, driver291.36s. iOS run created02:14:27Z, finished02:47:39Z; jobs overlapped local work, so do not sum as task wall-clock. Corrective file/analyzer 2026-10-19T05:00:43.7112686+00:00→2026-10-19T05:01:16.1832690+00:00. Exact active-analysis and external-wait duration is unknown; no fabricated total.

Next executable acceptance: user manually sends a new message with the formerly failing account in 测试群二 and confirms decryption/visibility on Android0.4.52. Existing async question is pending; no additional send authorization is inferred. If still failing, inspect sanitized public identity/key-share outcomes for that new attempt before any further product change. Local send-success alone cannot close AS6. The user's original >10s switching duration has not been fully remeasured or attributed after repair.
