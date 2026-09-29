# Wallet Monitor Email Only Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every wallet monitoring incident records and emails its signal without automatically changing global wallet control or ledger restriction state.

**Architecture:** Keep the incident and Outbox services intact. Remove control mutations from manual reserve monitoring, legacy monitoring, and the reconciliation/orphan scan services called by worker maintenance. Preserve explicit operator pause, existing restrictions, and each financial operation's own proof checks. A separate recovery command handles previously persisted pauses.

**Tech Stack:** Python 3.12, FastAPI, SQLAlchemy 2, pytest, PostgreSQL 16, Node test runner.

---

### Task 1: Baseline and current policy alignment

**Files:** `services/business-api/app/modules/wallet/manual_reserve_monitor.py`, `services/business-api/app/modules/wallet/incidents.py`, `services/business-api/app/modules/wallet/manual_control.py`, `services/business-api/app/modules/ledger/manual_reserve.py`, related wallet tests.

- [ ] Record SHA256 of the production API and worker images, current schema head, and the root checkout's wallet T2 changes. Import the approved 2026-09-28 T2 source changes into this isolated worktree after checking every target diff; leave unrelated root edits untouched.
- [ ] Run `pytest tests/business_api/wallet/test_manual_reserve_monitor.py tests/business_api/wallet/test_wallet_monitoring.py tests/business_api/wallet/test_wallet_incidents.py -q` with `PYTHONUTF8=1`, `PYTHONIOENCODING=utf-8` and the business API on `PYTHONPATH`. Record the actual baseline result; distinguish pre-existing failures.

### Task 2: Red tests for both monitoring paths

**Files:** `tests/business_api/wallet/test_manual_reserve_monitor.py`, `tests/business_api/wallet/test_wallet_monitoring.py`, `tests/business_api/wallet/test_manual_monitor_recovery.py`, `tests/business_api/wallet/test_reconciliation.py`, `tests/business_worker/test_wallet.py`.

- [ ] Add a parameterized manual monitor test for `MANUAL_PAYOUT_UNCERTAIN`, `MANUAL_UNALLOCATED_OUTFLOW`, coverage conflict, ledger integrity, and unavailable source. For each, assert incident code/severity and queued `wallet.alert`, while `WalletControl.withdrawals_paused`, global `WalletSafetyState.restricted`, and reserve `outgoing_restricted` remain at their pre-scan values. Assert a pre-existing pause remains set. Run the exact test and record the expected current failure.
- [ ] Change `test_partial_scan_preserves_incidents_and_never_claims_success` to assert the legacy monitor does not call `pause_on_reconciliation_mismatch`; add failed-email delivery and already-paused cases. Add a maintenance test proving a custody mismatch and an orphan order return signals without changing control flags. Run these tests and record red output.

### Task 3: Remove monitor-owned global control writes

**Files:** `services/business-api/app/modules/wallet/manual_reserve_monitor.py`, `services/business-api/app/modules/wallet/monitoring.py`, `services/business-api/app/modules/wallet/service.py`, `services/business-api/app/modules/wallet/safety.py`, `services/business-worker/app/tasks/wallet.py`, `services/business-api/app/modules/wallet/manual_control.py` only if its caller contract needs a narrow change.

- [ ] Change `ManualReserveMonitor._block` to emit the existing P0/P1/T2 incident and heartbeat without calling `apply_manual_pause`. Keep the `BLOCKED` result and no fresh reserve publication. Delete the automatic pause call from `WalletMonitoringService._run_locked_scan`; preserve the `WALLET_PAUSED` read-only signal when a separate source already paused funds. Make `WalletService._reconcile` and `WalletSafetyMixin.detect_orphan_external_orders` return mismatches without calling `pause_on_reconciliation_mismatch`, including when worker maintenance invokes them.
- [ ] Run the red tests from Task 2 and confirm they pass. Run the wallet monitor, incident, alert delivery, reserve, payout, receipt and ledger-focused suites. Verify that stale source, uncertain payout and broken ledger still reject operations at their own public application interfaces where required.

### Task 4: Contract, admin text, and review

**Files:** `frontend/src/wallet-incident-workflow.js`, `frontend/src/admin-manual-wallet-panel.js`, `frontend/tests/manual-wallet-panel.test.mjs`, `docs/runbooks/wallet-incident-recovery.md`, affected OpenAPI contract files.

- [ ] Update incident impact text to say email alert and no new automatic global pause, while showing an independently paused wallet truthfully. Keep the separate manual resume action and its permission checks. Add Node tests for incident detail and paused-state combinations.
- [ ] Run focused frontend tests, OpenAPI generation/check, `pwsh -NoProfile -File scripts/verify.ps1` after environment preflight, then specification-compliance review followed by domain and Quality/Security review. Record commands, exit codes, source hashes, and any existing failures in `docs/verification/2026-09-30-wallet-monitor-email-only.md`.

### Task 5: Production candidate

**Files:** release manifest and `docs/verification/2026-09-30-wallet-monitor-email-only.md`.

- [ ] Follow `docs/runbooks/admin-production-workflow.md`: compare the live image, Compose layers, schema, source hashes and active incidents; build an exact overlay candidate from the live base and rehearse rollback in isolated PostgreSQL. Deploy only approved wallet monitor/API/worker/frontend deltas and verify emails, accident audit, health, unauthorized rejection and absence of new automatic pause events. Do not clear the current persisted pause during deployment.
