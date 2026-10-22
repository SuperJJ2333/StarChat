# Account switching, connection feedback and retained history

## Recovery / authorization

- User reports both saved-account selection and logout followed by login: temporary service-unavailable toast, recovery over10seconds, slow history with loading feedback. iOS request is prevention of historical L04/L07, not a newly reproduced iOS incident.
- Scope: diagnose and fix existing lifecycle within approved cache-first design, ADR-0080 refresh recovery and ADR-0086 retained-identity safeguards. Preserve account isolation, server-authorized grant target, Olm fingerprint/database generation and Keychain; no clearing databases, automatic fresh-device recovery, real message sends or production rollout.
- Root sole writer, existing clean managed worktree interactive-cache-startup. Baseline16905e7f (runtime62dc76f2), installed Android0.4.61+2230, emulator-5556 UID10090 / firstInstall2026-09-26. Main D:/ workspace has unrelated changes and is not the source-edit target.
- Own targeted account-selection/reauthentication lifecycle, projection/watchdog behavior only when evidence identifies it, associated tests and these task documents. Broader authentication/E2EE decisions require ADR and DOMAIN then independent QUALITY review before implementation.
- Current phase: ordinary2232 installed; final local corrective verification complete; AS6 real-recipient delivery PASS_USER_CONFIRMED. Earlier stage snapshots below are historical. Started2026-10-19 06:16+08 approximately; exact first active-analysis interval unknown. Artifact root docs/verification/artifacts/2026-10-19/account-switch-readiness/.
- No .codegraph; no ongoing previous builds, wake lease or port forwards. Previous2230 test evidence applies unchanged baseline only.

## Acceptance ledger

| ID | Requirement | Status / evidence |
| --- | --- | --- |
| AS1 | Both login entrances have stage timings and classified service error; do not hide real outages | Lifecycle causes proved/fixed; full real switch timing and >10s attribution remain unmeasured |
| AS2 | A→B→A creates valid new projection owner; old account/room callbacks cannot populate new account even for shared room ID | RED missing coordinator proved; fixed bind and cleanup, real SQLCipher A/B/A same-room late-callback/deep-SQL coverage PASS |
| AS3 | Local cached history can render/scroll while optional network/history preparation continues after valid target identity | Shallow encrypted head readable while deep SQL held; strict Android native2232 original6audits and new rotation/room-key assertions PASS |
| AS4 | iOS continuity, authoritative device rotation, failed close/retry, Keychain temporarily unavailable and true fingerprint mismatch regressions | Shared focused153PASS; iOS18/26 native23seed+4restart each PASS, full unsigned compilePASS; physical iPhone/signing not verified |
| AS5 | Spec/domain then independent quality/security, appropriate scoped/final gates, fixed signer Android Debug install-r and original reproduction | Runtime and corrective fixture DOMAIN→independentQUALITY PASS; ordinary2232 installed; original fullFAIL preserved and file-only correction27PASS/analyze0; no production publication |
| AS6 | Former failing account sends a new group message that Android0.4.52 recipient can see | PASS_USER_CONFIRMED; direct human confirmation after ordinary2232 install; as6-user-acceptance-2232.json; old missing-key history not repaired |

## Evidence and next executable action

- baseline-closed-log-r1.json: fixed lifecycle codes only; old-client suspend6:17:08 completed in9ms in this observed process. Account selection begins6:17:27, full preflight6:17:28.747→6:17:30.184. This is incomplete process evidence and not total login timing.
- Proven root1: selection omitted a new coordinator; new account capture stayed retired. Bound a fresh unverified owner after exact continuity; failed binding retires/closes replacement. Original startup fallback never rebinds.
- Proven root2: real SDK old-token sync401 could clear newly adopted token. Retained login now drains/blackholes old sync before broker adoption; only persisted, exact adopted credentials restart normal SDK with immediate first poll. General backoff and genuine new401 remain. Pending login intents and lifecycle acquisition are fenced by synchronous revocation generation; stale catch cannot suspend newer owner.
- RED r2/r4 prove original defects; queued-logout-red and acquisition-red prove both intent windows. Final focused readiness-green-final153PASS. Earlier compilation/fixture failures remain separately labeled; fresh-status diagnostics identified OutsideTestException from an assertion executed in SDK runInRoot, moved that assertion to the test zone. No product bypass was made for that fixture.
- DOMAIN then independent QUALITY implementation approved. Analyze-r3 zero issues before final added tests; frozen gate will rerun analyze. Version scan of every registered worktree found maximum2230; reserve0.4.62+2231. Original emulator remains2230 until verified install-r.
- Native navigation observation confirms ordinary settings has logout/save flow; no arbitrary account names or UI bodies saved. Real login needs user-entered credentials if no usable saved grant; do not extract tokens/passwords. Actual >10s total remains unattributed, and the user phrase is not a literal in source.
- Next: freeze candidate, final shared analyze/full tests, conventional fixed-signer main and strict native builds; preserve-data install and native acceptance. Aggregate verify preflight blocked by no canonical .env; do not import primary's runtime secrets.
- iOS native build/device availability not established; shared tests cannot be called iPhone verification. No credentials requested in chat.


## Frozen candidate correction and iOS validation

At07:17+08 the additional Python version contract found pubspec2231 vs compiled AppConfig2230 (1FAIL/2PASS). The original runtime936507 source/build was not delivered. Its packaging pipeline finished PASS before attempted cancellation, but it is superseded by the independent version contract; full shared gate was canceled with exit-1, not PASS. Owned descendants were stopped and V/Y were released. No emulator install occurred.

AppConfig version defaults were corrected test-first (3PASS) and candidate re-frozen as11b72ec7754179370926377ade0a16e578801349. A complete new mobile Git archive was extracted over the build input; all2148 tracked mobile blobs verified against new HEAD before restarting final-shared-2231-b2 and main-2231-b2. Only that candidate can be delivered. No source commits while these gates/builds run.

Existing repository CI authentication verified read-only; no credential persisted. Validation-only branch codex/account-switch-readiness-2231 pushed at the frozen SHA. ios-compatibility.yml dispatched07:24:15+08 for same-source production native compile and iPhone15 iOS18/26 synthetic compatibility; no TestFlight/enterprise upload/publication job. ios-ci-dispatch.json and ios-ci-latest.json are authoritative. Native simulation does not replace retained-data physical iPhone verification.


## Native delivery reopened

At 2026-10-19T08:34:03.404715+08:00, ordinary0.4.62+2231 is installed via install-main-b2 PASS, SHA913037d775fac2f7f7fc7fc5437deeac0cf18ed77082358bf39922909b8ea19a, same UID10090/firstInstall. Strict native-r1 PASS8checks, wake setting restored. Cold-room sample3/14 PASS content_ready279/300/687ms; scope PARTIAL, no all-room claim.

Full frozen shared gate ended07:58:28+08, source stable, analyze0, exit1:6332PASS/9skips/1 test-fake failure. Fake init now adopts public user/device after successful super.init, original rotation assertions expanded; all30transitive host consumers and analyze PASS at08:05:30+08. Runtime/SDK/lock unchanged by that test-only correction.

AS6 OPEN: user says switched account can receive and locally send successfully, but Android0.4.52 recipient sees no event; switching emulator to other accounts works. User authorized one exact test message, native tool inserted none/sent0; user then manually sent the authorized text and confirmed not visible. Server normal encrypted events in the expected active room are accepted/outlierfalse, sender public key matches registry, not shadow-banned. Two same-name rooms exist, but only active8-member room has recent traffic including multiple senders. Public key counts are healthy; no messages or encryption secrets read. Current working account alias b09b2f6347 is distinct from failing event sender8712672654. Therefore metadata r7/r9 must not be misattributed to failed sender. User has been asked to return to failing account without another send.

Independent retained rotation source gap: SDK moves inner OlmManager device marker but not outer Encryption marker that grants Olm DB facade. ADR/plan supplement added; conditional DOMAIN approved. No product change yet; real red/persistence proof and independentQUALITY next.

iOS original run39176370952 production unsigned compile PASS, native phases skipped after3video host failures. Supplement39178296351 unchanged apps tree: Mac16905 baseline reproduces exact3host failures (comparisonPASS, original testsFAIL). iOS18 native seedFAIL, restartverifyPASS; overallFAIL preserved by explicit host outcome guard. iOS26 last known running; no overall native login PASS claim. Detailed log download did not yield a retained log; inspect safely via bounded streaming/range or CI artifacts.

## 2232 source-complete checkpoint

Recipient0.4.52 explicitly reports missing sender session key after reentering. Live failing-account read-only r10–r13 matches accepted-event public account/session identity; intended device targets are present, historical allowedAtIndex metadata is empty. No plaintext or cryptographic secrets obtained; no additional real sends.

Source now prevents incomplete room-key encryption from being acknowledged, awaits all room-key chunks, rejects stale member/device context before actual HTTP (including OTK and queued-transport waits), and forbids strict shares from entering the context-free deferred queue. Future-only rotation preserves old inbound history/authorization. Real SQLCipher/Olm tests prove recipient decryption and safe rejection/retry/reopen; protected DOMAIN then independent QUALITY implementation review PASS after pre-dispatch/replay findings and native-create cleanup/public override corrections.

Final paired candidate0.4.63+2232 reserved from all registered worktrees (maximum2231). Actual emulator still ordinary2231. Final impacted gate key-sharing-impact-r3 is running; original r1/r2 failure receipts remain. New-source shared full gate, Android main/native fixed-signer builds/install, iOS18/26 new native and unsigned production compile remain pending. AS6 live recipient validation remains OPEN; future rotation does not repair already-sent missing-key history.

Final impacted gate key-sharing-impact-r3 PASS {'pass': 541, 'skip': 0, 'failure_or_error': 0}, analyze0; paired version contract3PASS. DOMAIN→independentQUALITY final PASS. Candidate is ready for source freeze and final same-source shared/native gates.


## Installed2232 native checkpoint (2026-10-19T10:38:38.550878+08:00)

Frozen runtime2acebfdafcfa7637927913e37a8585dad261b568, paired0.4.63+2232. Main fixed-signature rebuilt APK SHAbf97af627699e77d58915c020fbec6be90c1c4a85de56f8d8c0492ea96509c1f; installed bytes match exactly. Ordinary install-r 2026-10-19T02:34:35.9039828+00:00 to 2026-10-19T02:34:53.7234724+00:00, UID10090 and firstInstall2026-09-26 04:06:20 retained. Diagnostic APK is not the current installed target.

Strict native 2026-10-19T02:28:54Z to 2026-10-19T02:34:07Z, driver291.36s/exit0: original6scenario audits plus new retained_rotation_olm_reopen_verified and room_key_share_roundtrip_verified all true; original stayon0 restored and own VM port removed. Synthetic identities only, zero additional real message sends.

Final frozen shared92541 is still running (analyze0), not yet PASS. New same-source iOS run39189028520 full unsigned production compile PASS; native iOS18 verify/iOS26 seed still running at last query. Ordinary2232 is ready for user-assisted old Android0.4.52 recipient test; async question pending. AS6 original historical trigger and already-sent missing-key history remain unproven/unrepaired; do not infer live resolution from synthetic tests.


## Final verification handoff (2026-10-19T13:30:59.825791+08:00)

- Runtime remains `2acebfdafcfa7637927913e37a8585dad261b568`; ordinary0.4.63+2232 installed as recorded above. Current test/docs-only follow-up changes no product or native-target input and needs no new APK/version.
- Original full FAIL6367PASS/9SKIP/2FAIL retained. Exact pendingWrites1 assumption corrected to >0 with all close/drain safety assertions retained, plus unconditional fixture teardown. Original archive alone1case PASS; full fixture27cases PASS (+3harness); analyze0. No mock expansion or product change. DOMAIN→independentQUALITY PASS; input equivalence and reuse explicitly recorded, not an all-green full command.
- iOS new-source run39189028520 completed: production unsigned compilePASS, iOS18/26 seed23+restart4 each PASS. OverallFAIL remains due host outcome guard; exact three video-cache failed names match baseline16905 in both jobs (ios-host-final-classification-2232.json); preserve classification/baseline artifacts and physical-device limitations.
- AS6 OPEN: recipient's missing sender key is confirmed; new2232 future-send real receipt pending. Root makes no new real sends; historical missing-key messages unrepaired. AS1 full real switch latency remains an observation gap, not a claimed performance measurement.
- All source-bound build/gate jobs finished; local mapping/VM forward/wake cleanup complete. No formal release/popup/download mutation. Four owned task docs and current-state entry only are eligible for CAS sync to primary, never mobile source.
- Next action: receive user result for one user-entered new2232→old0.4.52 group message; on failure collect sanitized public metadata for that attempt. Do not repeat independent completed gates on unchanged input.


## AS6 real-recipient acceptance (2026-10-19T13:47:19.547354+08:00)

Direct user confirmation: “原故障账号在‘测试群二’发送的新消息，Android 0.4.52 接收端可见”. AS6 now PASS_USER_CONFIRMED for new messages in the original failing-account/room/old-receiver scenario. Previous OPEN snapshots above are historical. Evidence: as6-user-acceptance-2232.json; current ordinary0.4.63+2232/runtime2ace/APKbf97 remains unchanged. No root new real send, new build/install or production publication.

No pending recipient question remains. Already-sent missing-key history is not restored by this confirmation. Full >10s switching timing and physical iPhone/signing acceptance remain distinct unmeasured/unverified items; no all-room/all-device or latency claim. Documentation-only update: links, owned scope, primary CAS and diff checks; existing runtime/native evidence reused.
