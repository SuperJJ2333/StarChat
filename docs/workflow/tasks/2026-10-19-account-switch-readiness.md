# Account switching, connection feedback and retained history

## Recovery / authorization

- User reports both saved-account selection and logout followed by login: temporary service-unavailable toast, recovery over10seconds, slow history with loading feedback. iOS request is prevention of historical L04/L07, not a newly reproduced iOS incident.
- Scope: diagnose and fix existing lifecycle within approved cache-first design, ADR-0080 refresh recovery and ADR-0086 retained-identity safeguards. Preserve account isolation, server-authorized grant target, Olm fingerprint/database generation and Keychain; no clearing databases, automatic fresh-device recovery, real message sends or production rollout.
- Root sole writer, existing clean managed worktree interactive-cache-startup. Baseline16905e7f (runtime62dc76f2), installed Android0.4.61+2230, emulator-5556 UID10090 / firstInstall2026-09-26. Main D:/ workspace has unrelated changes and is not the source-edit target.
- Own targeted account-selection/reauthentication lifecycle, projection/watchdog behavior only when evidence identifies it, associated tests and these task documents. Broader authentication/E2EE decisions require ADR and DOMAIN then independent QUALITY review before implementation.
- Current phase: final candidate verification. Started2026-10-19 06:16+08 approximately; exact first active-analysis interval unknown. Artifact root docs/verification/artifacts/2026-10-19/account-switch-readiness/.
- No .codegraph; no ongoing previous builds, wake lease or port forwards. Previous2230 test evidence applies unchanged baseline only.

## Acceptance ledger

| ID | Requirement | Status / evidence |
| --- | --- | --- |
| AS1 | Both login entrances have stage timings and classified service error; do not hide real outages | Investigating; current-PID sanitized native baseline captured |
| AS2 | A→B→A creates valid new projection owner; old account/room callbacks cannot populate new account even for shared room ID | RED missing coordinator proved; fixed bind and cleanup, real SQLCipher A/B/A same-room late-callback/deep-SQL coverage PASS |
| AS3 | Local cached history can render/scroll while optional network/history preparation continues after valid target identity | Shallow encrypted head readable while deep SQL held after account switches; native candidate pending |
| AS4 | iOS continuity, authoritative device rotation, failed close/retry, Keychain temporarily unavailable and true fingerprint mismatch regressions | Shared focused gate153PASS including retained identity, preflight, rotation, reinstall safeguards; no native iOS result claimed |
| AS5 | Spec/domain then independent quality/security, appropriate scoped/final gates, fixed signer Android Debug install-r and original reproduction | DOMAIN→independent QUALITY implementation PASS; final frozen shared gate/build/install pending; no production publication |

## Evidence and next executable action

- baseline-closed-log-r1.json: fixed lifecycle codes only; old-client suspend6:17:08 completed in9ms in this observed process. Account selection begins6:17:27, full preflight6:17:28.747→6:17:30.184. This is incomplete process evidence and not total login timing.
- Proven root1: selection omitted a new coordinator; new account capture stayed retired. Bound a fresh unverified owner after exact continuity; failed binding retires/closes replacement. Original startup fallback never rebinds.
- Proven root2: real SDK old-token sync401 could clear newly adopted token. Retained login now drains/blackholes old sync before broker adoption; only persisted, exact adopted credentials restart normal SDK with immediate first poll. General backoff and genuine new401 remain. Pending login intents and lifecycle acquisition are fenced by synchronous revocation generation; stale catch cannot suspend newer owner.
- RED r2/r4 prove original defects; queued-logout-red and acquisition-red prove both intent windows. Final focused readiness-green-final153PASS. Earlier compilation/fixture failures remain separately labeled; fresh-status diagnostics identified OutsideTestException from an assertion executed in SDK runInRoot, moved that assertion to the test zone. No product bypass was made for that fixture.
- DOMAIN then independent QUALITY implementation approved. Analyze-r3 zero issues before final added tests; frozen gate will rerun analyze. Version scan of every registered worktree found maximum2230; reserve0.4.62+2231. Original emulator remains2230 until verified install-r.
- Native navigation observation confirms ordinary settings has logout/save flow; no arbitrary account names or UI bodies saved. Real login needs user-entered credentials if no usable saved grant; do not extract tokens/passwords. Actual >10s total remains unattributed, and the user phrase is not a literal in source.
- Next: freeze candidate, final shared analyze/full tests, conventional fixed-signer main and strict native builds; preserve-data install and native acceptance. Aggregate verify preflight blocked by no canonical .env; do not import primary's runtime secrets.
- iOS native build/device availability not established; shared tests cannot be called iPhone verification. No credentials requested in chat.

