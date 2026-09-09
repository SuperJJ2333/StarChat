# Monitor snapshot synchronization repair

## Verified production cause

All times below are CST/Hong Kong (UTC+8), September 9, 2026.

- Incident `3f86ae92-038c-4816-b40d-b92a887bbb6e`, generation 2, reopened at 09:40:51.992529.
- Worker log 09:40:51.942537: observation 5745/run 6189, SOLID_HEAD_STALE, solid head age 180942ms against the unchanged 180000ms bound. Heartbeat age was only 32691ms; reconciliation SOURCE_MATCHED and stored run status OK. This was a stale solid-block snapshot, not a failed SMTP delivery or proof of lost funds.
- At 09:40:52.022734, the worker read healthy observation 5746/run 6190, solid head age 118022ms. The unhealthy-to-healthy log interval was ~80ms. Immutable observer rows confirm the checkpoint advance.
- Event `8ad542c1-c261-4f75-9988-0bbf3f69aab0` is wallet.incident.escalated, created 12:21:01.316067, SMTP acceptance 12:21:02.313994, published 12:21:02.318999, attempt_count=1.
- This incident generated 33 delivered events today: reopening at 09:40:54 plus 32 subsequent unacknowledged P0 reminders, through 12:21:02. Every row has attempt_count=1 and an SMTP receipt. Acknowledgement at 12:22:08.935375 stopped this reminder sequence. Database records do not support a 09:39 send time for this event.
- Separate live snapshots showed coverage CURRENT then WAITING as the healthy observer checkpoint moved. Code requires exact discovery/observer checkpoint alignment, so asynchronous discovery can cause waiting without new events.

Read-only investigation scripts: `artifacts/2026-09-09/incident-check/mail_event.py`, `observer_window.py`, `read_status.py`. No credentials, addresses or ledger amounts are included in this evidence.

## Implementation and review

Plan: `docs/superpowers/plans/2026-09-09-monitor-snapshot-synchronization.md`; decision: `docs/adr/0043-monitor-snapshot-synchronization.md`.

Synchronize discovery through the existing public funding scanner with funds_enabled=False and coverage registration enabled. No receipt ingestion/finality calls are possible through that callback. Retry only incomplete coverage/source-change results, at most three attempts, stopping immediately on completion or nontransient failure. Before classifying a valid stale/unhealthy snapshot, resample once after 200ms; do not alter timestamps, thresholds or acceptance criteria. All source reads/discovery and waits are outside the proof's financial transaction.

Domain/specification review preceded quality/security review; reviewer found no blocking issue. Added the suggested combined stale-snapshot/new-checkpoint regression. Existing auth, commit-boundary freshness, idempotency, ledger and coverage tests remain applicable. Email escalation policy is unchanged; alerts have not been muted.

## Verification

Initial new regressions failed for the intended missing resample and discovery attempts, then passed. Final focused suite: 140 passed, one existing Starlette/httpx deprecation warning. Includes real discovery on checkpoint-only updates, registered pending new events with no credit, bounded retries, combined stale replacement/checkpoint advancement, source failures, coverage conflicts, replay and maintenance controls. Evidence: `artifacts/2026-09-09/monitor-sync/focused.txt`.

An initial focused invocation omitted worker PYTHONPATH and produced 14 module-import failures; corrected the invocation and reran successfully. Full verification uses the repository script's configured worker path and completed with exit 0 / Verification: PASS, recorded in `artifacts/2026-09-09/monitor-sync/verify.txt`: 1399 business tests passed, 34 skipped, 66 mobile boundary tests passed, and UI contract/import/AST/migration/OpenAPI/Compose checks passed. The extra combined boundary regression was included in the final 140-test focused rerun after full-suite collection. Existing dependency deprecation warnings remain documented in the log; skipped tests are not claimed executed.

## Release preparation

Release `/opt/starchat/releases/monitor-sync-20260909` prepared successfully. API base `494464f3abc9143b5794af92179ee20a2add41803283d94eb4e19e0a893a015b`; worker base `239f08de81d9f5105c7d687fac2d3659afc47eb9dea2e33825a5710fbc2d9a87`. Scoped source hashes matched production before edits. Existing image tags resolved to pinned IDs; actual environment values and rendered Compose configuration were checked without exposing secrets.

Published API `3a6632aaeda8e3cc9acb69de7aa77d611cc94466b34d1c0f8bf76ca106cdcff8`; worker `27bc9f7de31fb5803e3180e6817e319cced9fc1462379146ddf1dc4350925eb5`. No database migration. Publish returned PASS: container health/running, five scoped source hashes, nginx validation/reload and pinned-image identity checks passed. Existing worker main diff against production consisted only of discovery callback wiring. Public anonymous diagnostic endpoint returned 401 as expected.

Post-release monitor heartbeat at 13:43:12 and 13:44:13 CST reported MANUAL_WALLET_PAUSED (after source and coverage checks), rather than MANUAL_COVERAGE_PENDING. Latest protected read shows incident still ACKNOWLEDGED/version106 and funds paused; no incident acknowledgement/closure or fund recovery was executed by the agent. Evidence: `artifacts/2026-09-09/monitor-sync/post-status.json`. These observations demonstrate sampled cycles, not a guarantee that future genuine source failures cannot occur.

Rollback: `python3 /opt/starchat/releases/monitor-sync-20260909/release.py rollback`, which pins both previous images and retains their original Compose configuration. No state/database rollback is involved. SSH access was intermittently unstable; successful execution used the user's authorized direct/proxy transport and retained host-key verification.
