# Incident b547fb99-dc66-4ab0-b306-6043ca044b56 investigation

Date: 2026-09-08 (Asia/Hong_Kong).
Scope: read-only correlation of MANUAL_SOURCE_UNHEALTHY incident time with observer records.

Outcome: blocked before remote authentication; no production records read or modified.
- Configured SSH ProxyCommand could not locate connect executable.
- Explicit Git connect.exe path with HTTP proxy: connection closed by proxy/remote path before SSH authentication.
- Direct SSH with ProxyCommand/ProxyJump disabled: banner exchange timeout.
- Explicit SOCKS proxy: connection closed before SSH authentication.
- Exact incident UUID search in local verification Markdown/JSON/text found no matches.

The incident timestamp, historical observer run and observation rows, present incident state, and specific triggering predicate remain unverified. No conclusion of balance discrepancy or asset loss is supported by these results.
Next: restore SSH reachability, query only incident timestamps/status and observer health/reconciliation metadata around those timestamps; exclude addresses, balances, credentials and full database exports.

## Successful read-only follow-up

Direct SSH succeeded on 2026-09-08 at 09:39 UTC with ProxyCommand and ProxyJump disabled. The HTTP localhost:7897 proxy still closed the SSH connection.

Verified production evidence (timestamps UTC; Hong Kong is UTC+08:00):
- Supplied event b547fb99-dc66-4ab0-b306-6043ca044b56 is wallet.incident.escalated, created 09:29:25.823181, published 09:29:26.961053; delivery receipt created 09:29:26.959571.
- Underlying incident 3f86ae92-038c-4816-b40d-b92a887bbb6e: MANUAL_SOURCE_UNHEALTHY, opened 09:08:55.542559, last_seen 09:08:55.621335, generation 1, OPEN, condition_active true, no cleared/resolved timestamp at inspection.
- Observer observation 3923 at 09:06:37.956: stable_balance=0, RECONCILIATION_UNVERIFIED.
- Observation 3924 at 09:07:32.539: stable_balance=1, RECONCILIATION_UNVERIFIED, solid block 86062178 timestamp/checkpoint 09:05:36.
- Run 4368 at 09:08:04.230: ERROR / SNAPSHOT_FAILED; checkpoint remained 09:05:36, no replacement observation.
- At incident opening, last observation age was 83.003 seconds and run heartbeat age 51.313 seconds, but solid block age was 199.543 seconds. This exceeded the 180-second solid-head freshness limit used by manual wallet source consumers. Thus fresh=false, and failed snapshot could no longer use the fresh-pending exception. Source unhealthy protection is consistent with the stored timeline and deployed source logic.
- Run 4369 / observation 3925 at 09:09:00.374: OK, no error, stable_balance=1, SOURCE_MATCHED; solid timestamp 09:07:03. Recovery was approximately 4.831 seconds after incident opening.
- At 09:42:11.286 monitoring attempt: last_error_code MANUAL_WALLET_PAUSED. wallet_controls.withdrawals_paused=true, pause_reason MANUAL_SOURCE_UNHEALTHY.
- Latest sampled run 4429 / observation 3985: OK, no error, stable_balance=1, SOURCE_MATCHED.
- BALANCE_DISCREPANCY count from 09:03 UTC to query time: 0.

Conclusion: a snapshot collection failure followed by stale solid-block evidence triggered a protective wallet pause. The supplied notification is escalation of the unresolved original incident, not evidence of a new failure at 09:29. Observer sampling recovered, while the wallet pause and unresolved incident persisted. These observations do not prove asset loss. The lower-level reason for SNAPSHOT_FAILED (e.g. transport/provider failure) has not been established.

Access: SELECT-only PostgreSQL transactions with SET TRANSACTION READ ONLY; SQLite mode=ro; redacted status JSON and installed source inspection. No financial state, incident state, credentials, or production configuration was modified. No complete addresses, balances or database exports were collected.
