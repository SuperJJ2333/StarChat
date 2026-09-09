# Manual source incident follow-up

Scope: corrective follow-up to the approved admin-console modernization plan. Owned changes: disabled recovery entry in `frontend/src/admin-manual-wallet-panel.js`, its focused test, and cache version references in `admin-home.js` / `admin.html`. No financial or incident state mutation.

Read-only production findings on 2026-09-08:

- Notification `ffbd23b8-7772-4c2d-a0c6-c9c03142bcc9` is `wallet.incident.escalated`, created at 12:14:15.210936 UTC (20:14:15 Hong Kong), published once with attempt_count=1.
- Its incident is `3f86ae92-038c-4816-b40d-b92a887bbb6e`, opened at 09:08:55.542559 UTC (17:08:55 Hong Kong), generation 1, still OPEN and unacknowledged. Subsequent notifications occur approximately every five minutes. This notification is not a newly opened incident on deposit submission.
- The incident service escalates OPEN P0 incidents on 300-second slots. An authenticated incident acknowledgement stops this unacknowledged escalation; it does not release funds.
- Code-path check: `api/manual_wallet.py` deposit submission delegates to `DepositIntentService.create` in `modules/wallet/funding.py`; it does not call incident escalation or send P0 mail. The reported mail's outbox metadata independently identifies it as a monitor escalation.
- Latest inspected observer runs 4722–4724 were OK; observations 4278–4280 had stable_balance=1 and SOURCE_MATCHED. Earlier diagnostic logs included BALANCE_UNSTABLE / RECONCILIATION_PENDING while awaiting consistent evidence. These current observations do not themselves clear an incident or authorize recovery.
- A second unresolved incident, MANUAL_BACKING_DEFICIT, is also OPEN. Both require review before the control can resume. Wallet remains paused with MANUAL_SOURCE_UNHEALTHY.

UI defect: the PAUSED state omitted the recovery form when unresolved_incidents was nonzero, making the entry disappear. The correction displays a disabled recovery button plus explicit acknowledgement, monitor review, resolution, and refresh instructions. Existing backend gates and absence of a mutation form remain intact.

Verification: focused regression failed because the recovery entry was missing, then passed after the change. All 93 frontend tests passed, including a repeat after cache version updates. Full verification output: `artifacts/2026-09-08/manual-source-incident-ffbd23b8/verify.txt`.

Full repository verification completed with `Verification: PASS`: backend 1381 passed / 34 skipped, followed by boundary, static, migration, OpenAPI and Compose checks. Existing dependency deprecation warnings are recorded in the output; this frontend correction does not change those dependencies.

Recovery: view and acknowledge the P0 incident using the administrator's operation credential; run the manual monitor evidence review; resolve cleared incidents while retaining the pause; refresh; invoke the guarded manual-wallet resume. If evidence review rejects any condition, investigate the returned reason instead of bypassing the guard.

Independent specification/security review found no blockers and independently passed all 35 manual-wallet-panel tests. Static correction deployed to production with preimages retained under `/opt/starchat/releases/recovery-entry-20260908/before/`. Three public HTTPS resources returned 200 and matched their release hashes, including cache-busted module references. Evidence: `artifacts/2026-09-08/manual-source-incident-ffbd23b8/http-verified.json`. No API, worker, migration, wallet control, or incident record was changed by this correction.
