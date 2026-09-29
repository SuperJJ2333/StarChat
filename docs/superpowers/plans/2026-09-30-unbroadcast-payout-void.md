# Unbroadcast Payout Void Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow a verified administrator to void an already claimed but never broadcast manual payout, preserving its history and exactly reversing its hold and source conversion.

**Architecture:** Add a distinct terminal `VOIDED` order state and owner-authorized command. Acquire fresh read-only chain observation outside the financial transaction; recheck its identity and expiry under budget/order locks before compensating. The command reuses the exact linked conversion-reversal application interface and adds immutable idempotency, audit and Outbox records.

**Tech Stack:** Python 3.12, FastAPI/Pydantic, SQLAlchemy 2/Alembic, PostgreSQL 16, pytest, vanilla JS admin console.

---

### Task 1: Schema and state machine red tests

**Files:** `services/business-api/app/modules/wallet/manual_payout_models.py`, new Alembic revision after the live schema head, `tests/business_api/wallet/test_manual_payouts.py`, PostgreSQL migration tests.

- [ ] Import the production-applied 0089–0091 migration chain into this worktree without editing its contents, verify a unique head, and use that head as the new expand-only revision parent. Add a test that `UNKNOWN` with claim fields can become `VOIDED` and cannot be mutated afterward; keep `UNKNOWN → CANCELLED`, `SETTLED → VOIDED`, and candidate-bearing voids rejected. Run to record red.
- [ ] Extend status and claim check constraints and the PostgreSQL `wallet_manual_order_guard` function for `UNKNOWN → VOIDED`, preserving immutable claim fields and disallowing subsequent changes. Mirror the transition in the ORM guard. Keep migration downgrade non-destructive and test a live-shape PostgreSQL upgrade.

### Task 2: Financial compensation red tests

**Files:** `tests/business_api/wallet/test_manual_payouts.py`, `tests/business_api/wallet/test_payout_conversion.py`, `services/business-api/app/modules/wallet/manual_payouts.py`, `services/business-api/app/modules/wallet/conversions.py`, `services/business-api/app/modules/ledger/service.py`.

- [ ] Build claimed `UNKNOWN` fixtures both with USDT funding and with CAIBI funding plus a later `final_receive` adjustment. Assert the exact remaining HOLD is released, the full original conversion is reversed, pending count decreases once, and both asset ledgers balance. Assert insufficient available USDT, candidate txid, existing payout event, stale chain evidence, suspicious outflow, concurrent settlement, and replay with changed payload reject atomically. Run and record red.
- [ ] Implement `void_unbroadcast` with strict owner identity, independent operation verification, signed-wallet non-broadcast declaration, reason code, expected order version and idempotency key. Use `_payable(row, quote)` for the final HOLD, then `reverse_payout_conversion` for the original conversion amounts. Its existing linked CAIBI reversal debits only `PLATFORM_CLEARING`, which remains allowed under the old outgoing restriction; do not introduce a general restriction bypass. Audit and Outbox are committed with the order and balanced entries.
- [ ] Run red tests to green and verify the existing `REQUESTED` cancel, claimed settlement, adjusted-rate, ledger restriction, and concurrent PostgreSQL suites still pass.

### Task 3: Chain evidence and authorized API

**Files:** `services/business-api/app/integrations/tron/admin_query.py`, `services/business-api/app/api/manual_wallet_operations.py`, `services/business-api/app/api/wallet_operations.py`, OpenAPI output, new API tests.

- [ ] Add a read-only observation operation that returns a bounded evidence identity: source, checkpoint, observation ID, reconciliation status and matching or suspicious official outflows since claim. Do not expose full addresses in logs or email. Test source unavailable, incomplete/old scan, exact and ambiguous transfer, and source changed between preflight and commit.
- [ ] Add `POST /api/v1/wallet/manual/operations/payouts/{order_id}/void-unbroadcast` using the existing owner/admin grant and operation-password or TOTP authorization pattern. Body includes expected version, reason code and explicit declaration; header supplies the idempotency key. Test 401, 403, stale login, wrong owner, proof replay, payload conflict and commit-time grant revocation. Generate and check OpenAPI.

### Task 4: Console and user projection

**Files:** `frontend/src/admin-api.js`, `frontend/src/admin-manual-wallet-panel.js`, `frontend/src/wallet-incident-workflow.js`, `frontend/tests/manual-wallet-panel.test.mjs`, mobile wallet status labels/tests if the shared contract displays the new status.

- [ ] Add an owner-only action on `UNKNOWN` orders: display original order, final chain payable amount, current evidence status, warning, explicit never-broadcast checkbox, operation verification, pending/error/unknown-result states and the unchanged idempotency key on retries. Show `VOIDED` as “已撤销（确认未广播）” and retain order history. Add focused DOM tests.
- [ ] Run frontend and affected Flutter status tests, then specification-compliance review followed by domain and Quality/Security review. Record all evidence and remaining risks in `docs/verification/2026-09-30-unbroadcast-payout-void.md`.

### Task 5: Production operation and recovery

**Files:** deployment manifest, `docs/verification/2026-09-30-unbroadcast-payout-void.md`, task record.

- [ ] Compare current production images, Compose, schema and file hashes; prepare isolated PostgreSQL restore and rollback-compatible candidate. Apply migration before compatible API rollout; verify unauthorized rejection, exact API/static hashes, balanced-ledger rehearsal and absence of new errors.
- [ ] With the real wallet administrator's authenticated session and independent operation proof, re-read order `3e728fe3-7343-4036-b9a0-646e56a46457`, submit the declared never-broadcast void once and verify the immutable result, reversal entries, pending count, audit and Outbox. If proof is unavailable or any check fails, leave `UNKNOWN` and report the exact blocker.
- [ ] Re-run incident review and resolution for `75c01afc-29e7-416f-9609-581973994b14`; use the separate owner-authorized control resume command, then read back controls and an additional monitor cycle. Never flip control columns directly or infer restoration from the order status alone.
