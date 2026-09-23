# Support order workflow Implementation Plan

> **For agentic workers:** Use executing-plans with bounded parallel domains under dispatching-parallel-agents; user explicitly wants only main. All work stays on main with disjoint file ownership. No new branches or production operations.

**Goal:** Deliver two-step estimate-first recharge/payout, exclusive verified support processing, staff activation and management notifications.
**Architecture:** Extend existing RechargeService, wallet receipt and payout public services, preserve ledger and approvals; separate staff activation from financial modules. Existing Flutter and HTML components remain the visual foundation.
**Tech Stack:** FastAPI/SQLAlchemy/Alembic/PostgreSQL, Flutter, existing vanilla JS admin/demo.

## Contracts and ownership

Root: recharge service/models/api, wallet public receipt integration and payout timeout/lease, migration0084, main wiring, shared OpenAPI and final verification. Auth implementer: identity staff activation module/router and tests, identity login integration, migration0085 (down_revision=0084_support_order_workflow); report main wiring without editing main.py. Flutter implementer: manual_wallet_page.dart, manual_wallet_api.dart, business_phone_contracts.dart/client recharge methods only if needed, wallet tests, phone-flows.js demo and matching UI registry entries; no admin files. Admin implementer: admin-recharge-panel.js/admin-api.js/order workspace tests and notification presentation; no auth login files.

Root HTTP contracts (existing routes preserved):
- GET /recharge/official-payment -> {network,address,config_version}; authenticated user; never choose payment destination from arbitrary client input.
- POST /recharge/requests/{id}/evidence body {txid}; Idempotency-Key. User owns order; no credit from claim.
- POST /recharge/admin/requests/{id}/claim body {}; Idempotency-Key -> order view + claim_token for current actor only.
- POST .../{id}/heartbeat body {claim_token}; renew5min lease after actor/stage checks.
- POST .../{id}/verify-payment body {claim_token,txid,log_index}; trusted chain check, authoritative ownership; never credit. Returns order view/payment_verified.
- POST .../{id}/prepare-settlement {claim_token,final_rate}: derive a pending adjustment solely from the verified order; independent administrator approval through existing adjustment review. POST .../{id}/execute-settlement {claim_token}: scoped proof and current claim required; execute approved money then idempotent registration. Historical cases retain /bind and /complete-binding.
- GET /recharge/admin/events?cursor&limit -> {items:[{id,kind,order_id,event_type,created_at}],next_cursor}; durable existing Outbox, no secrets.
Order additions are optional backward-compatible fields: expires_at, processing_stage, official_payment, payment_verified, actual_received_usdt, claimed_by, claim_expires_at, final_rate/final_caibi_amount existing. Claims absent for old orders must not invent historical receipts.
Admin payout uses scoped /admin/support-orders/payouts adapters over existing public claim/rate/txid/reconcile services; user withdraw estimates remain references while final_receive is authoritative.

## Task 1 — Financial coordination and evidence
- [x] Add tests in tests/business_api/recharge/test_support_order_workflow.py for double claim/lease, stale actor token, two-hour boundary, late evidence, proof reuse, cancellation and no unverified settlement.
- [x] Run `py -3.12 -m pytest tests/business_api/recharge/test_support_order_workflow.py -q` with PYTHONPATH=services/business-api; record red.
- [x] Add expand-only0084 with durable claim/evidence/payment snapshots. Implement short DB lock/CAS operations with same idempotency/audit/Outbox discipline. Public wallet receipt API owns receipt reservation/consumption; coordinator never writes wallet tables directly.
- [x] Enforce verified evidence before binding/execution/final registration; repair and old receipt consumers reject reserved/consumed receipts. Keep uncertain execution occupied; mark overdue cases for review without recredit/unfreeze.
- [x] Run recharge/wallet/ledger focused suites and isolated PostgreSQL contention checks; record green and reviewed invariants.

## Task 2 — Staff activation/authentication
- [x] Add red tests for ordinary users, inactive staff, changed contact, wrong/replayed/expired OTP, provider outage, duplicate activation, and separate admin sessions.
- [x] Implement bound-channel activation using existing OTP providers and server-fetched official staff identity; additive migration0085. Keep admin password login compatible and financial step-up intact.
- [x] Add first-activation UI to current admin login, real gateway methods and dedicated tests. Run identity and frontend focused suites.

## Task 3 — Mobile and demo
- [x] Add failing wallet tests for no first-step staff/payment address, decimal keyboard, estimate-first presentation, persisted second step, actual-final amounts and cancellation/overdue states.
- [x] Reuse current cards/steps/text styles. Add txid input in payment step only; GET official-payment is gateway-backed; no first-step FX outage should masquerade as an amount.
- [x] Keep payouts payment authorization and existing wallet API; clearly label estimated vs final settled amounts. Synchronize phone-flows demo and registry; run focused Flutter/UI tests and analyze.

## Task 4 — Support workstation
- [x] Add red tests for competing ownership, read-only other actor, heartbeat failure, stale list, missed/duplicate notifications and forbidden responses.
- [x] Integrate real claim/verify/settlement/review operations and existing payout panel, durable cursor notifications; never mark credited based on request success alone.
- [x] Run frontend tests and route contract assertions.

## Task 5 — Review and deliver
- [x] Write financial/auth ADR reflecting approved spec. Specification check precedes security/quality review; fix uncovered bypasses before full gate.
- [x] Export OpenAPI, validate single0087 head and PostgreSQL migrations. Run full Flutter/analyze/frontend and scripts/verify.ps1 once on frozen final inputs, reusing unchanged exact evidence only.
- [x] Update task/evidence/current-state; commit only scoped source. Report implementation, tests, and separately not deployed/not installed; no real SMS/funds without an explicit test need.

完成记录：本地实现、独立规格/质量安全复审及完整门禁均通过，详见 docs/verification/2026-09-23-support-order-workflow.md。未部署或安装APK。
