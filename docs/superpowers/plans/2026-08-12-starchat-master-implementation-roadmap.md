# 六合通 Master Implementation Roadmap

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the current Matrix/Element/Bot skeleton into the approved 六合通 product while preserving E2EE boundaries and immutable financial accounting.

**Architecture:** Keep Matrix as an isolated encrypted communications domain. Add a FastAPI modular monolith as the authoritative business and financial domain, a Flutter Android/iOS client, a React administration client, and asynchronous workers backed by PostgreSQL Outbox. Deliver the system in independently testable phases; write a detailed phase plan before changing that phase.

**Tech Stack:** Python 3.12, FastAPI, SQLAlchemy 2, Alembic, PostgreSQL 16, Redis 7, Flutter/Dart, Matrix SDK, WebRTC/TURN/SFU, React/TypeScript/Vite, Docker Compose, OpenAPI.

## Global Constraints

- Every private chat, group chat, support room, attachment, voice message, and call is end-to-end encrypted.
- The platform never stores user recovery keys, room keys, message plaintext, or plaintext attachments.
- CAIBI uses two decimal places; USDT uses six; application code uses Decimal and database code uses NUMERIC, never float.
- Ledger transactions and entries are append-only and balanced per asset; corrections use reversal transactions.
- CAIBI and USDT are isolated; no exchange, USDT P2P transfer, or USDT red packets.
- Financial write APIs require Idempotency-Key and stable error codes.
- Matrix messages and bots never determine authoritative financial state.
- Production containers and dependencies are version/digest locked; production never uses latest.
- Development uses SandboxCustodyProvider until a provider passes the common contract suite.
- Android ships as a controlled APK and iOS ships through TestFlight.

---

## Delivery Dependency Graph

```text
Phase 0 Foundation
  ├─> Phase 1 Business Core ─> Phase 2 Identity ─> Phase 3 Support
  │                              └───────────────> Phase 7 Mobile Foundation
  ├─> Phase 4 Ledger ─> Phase 5 Red Packet ─────> Phase 7 Mobile Features
  ├─> Phase 6 Wallet ───────────────────────────> Phase 7 Mobile Features
  ├─> Phase 7 Mobile/E2EE ─> Phase 8 Encrypted Calls
  └─> Phase 9 Admin Web
All phases ─> Phase 10 Production Readiness
```

## Phase 0: Foundation Repair and Repository Governance

**Detailed plan:** `docs/superpowers/plans/2026-08-12-foundation-repair-implementation.md`

**Files:**
- Create: `AGENTS.md`
- Create: `infra/AGENTS.md`
- Create: `services/matrix-bot/AGENTS.md`
- Create: `scripts/lib/TemplateTools.psm1`
- Create: `tests/powershell/Test-TemplateTools.ps1`
- Create: `tests/matrix_bot/test_room_policy.py`
- Create: `scripts/verify.ps1`
- Modify: `.gitignore`
- Modify: `scripts/init_matrix.ps1`
- Modify: `infra/synapse/homeserver.yaml.template`
- Modify: `docker-compose.yml`
- Modify: `.env.example`
- Modify: `services/matrix-bot/app/settings.py`
- Modify: `services/matrix-bot/app/matrix_client.py`
- Modify: `services/matrix-bot/requirements.txt`

**Produces:** Strict configuration rendering, pinned/validated infrastructure inputs, notification-bot room restrictions, repeatable tests, and repository Agent rules.

**Exit gate:** `pwsh -NoProfile -File scripts/verify.ps1` passes without Docker; when Docker is available, rendered config validation and Compose health checks pass.

## Phase 1: Business Service Skeleton and Shared Contracts

**Detailed plan output:** `docs/superpowers/plans/2026-08-12-business-core-implementation.md`

**Files:**
- Create: `services/business-api/pyproject.toml`
- Create: `services/business-api/app/main.py`
- Create: `services/business-api/app/core/config.py`
- Create: `services/business-api/app/core/database.py`
- Create: `services/business-api/app/core/errors.py`
- Create: `services/business-api/app/core/idempotency.py`
- Create: `services/business-api/app/core/outbox.py`
- Create: `services/business-api/alembic.ini`
- Create: `services/business-api/migrations/`
- Create: `services/business-worker/`
- Create: `packages/api-contracts/openapi/`
- Create: `tests/business_api/`

**Interfaces produced:**
- `AppError(code: str, status_code: int, message: str, field_errors: list[FieldError])`
- `IdempotencyService.begin(scope, key, request_hash)` and `complete(record, response)`
- `OutboxPublisher.enqueue(topic, aggregate_id, payload)` within the caller transaction
- `/api/v1/health/live`, `/api/v1/health/ready`, and generated OpenAPI

**Exit gate:** Real PostgreSQL integration tests prove migrations, idempotent writes, stable errors, and atomic Outbox persistence.

## Phase 2: Identity, Email, Invitations, Devices, RBAC, and Audit

**Detailed plan output:** `docs/superpowers/plans/2026-08-12-identity-access-implementation.md`

**Files:**
- Create: `services/business-api/app/modules/identity/`
- Create: `services/business-api/app/modules/audit/`
- Create: `services/business-api/app/integrations/matrix_admin.py`
- Create: `services/business-worker/app/tasks/email.py`
- Create: `tests/business_api/identity/`
- Create: `tests/business_api/audit/`

**Interfaces produced:**
- `InvitationService.issue()` and `consume()`
- `RegistrationService.register()` state machine: `PENDING_EMAIL -> PENDING_MATRIX -> ACTIVE`
- `MatrixAdminGateway.ensure_user(localpart, password)` with idempotent recovery
- `TokenService.issue_pair()`, `rotate_refresh_token()`, and `revoke_family()`
- `RbacService.require(permission)` and append-only `AuditWriter.record()`

**Exit gate:** No account becomes active before email and Matrix creation succeed; password recovery revokes sessions and places a 24-hour withdrawal hold.

## Phase 3: Official Support and Queueing

**Detailed plan output:** `docs/superpowers/plans/2026-08-12-support-platform-implementation.md`

**Files:**
- Create: `services/business-api/app/modules/support/`
- Create: `tests/business_api/support/`
- Extend: `packages/api-contracts/openapi/starchat-v1.yaml`

**Interfaces produced:**
- `SupportIdentityView` with server-authoritative badge, color, number, role, and description
- `SupportQueueService.open_ticket()`, `assign_next()`, `transfer()`, and `close()`
- Signed/cacheable support identity endpoint
- Queue event stream containing metadata only, never room plaintext

**Exit gate:** Ordinary Matrix profiles cannot display a trusted badge; queue assignment follows online status, skills, and least-active ordering; transfer rotates future room keys through the clients.

## Phase 4: CAIBI Ledger, Adjustments, Approvals, and Transfers

**Detailed plan output:** `docs/superpowers/plans/2026-08-12-point-ledger-implementation.md`

**Files:**
- Create: `services/business-api/app/modules/ledger/`
- Create: `services/business-api/app/modules/ledger/AGENTS.md`
- Create: `tests/business_api/ledger/`

**Interfaces produced:**
- `LedgerService.post(transaction: LedgerTransactionDraft) -> LedgerTransaction`
- `LedgerService.reverse(original_id, reason_code, actor_id)`
- `PointTransferService.transfer(sender_id, receiver_id, amount, idempotency_key)`
- `AdjustmentWorkflow.submit()`, `finance_review()`, `admin_review()`, and `execute()`

**Exact transfer rule:** `fee = max(Decimal("0.01"), round_half_up(amount * Decimal("0.005"), 2))`; debit sender by amount plus fee, credit recipient by amount, credit platform fee by fee.

**Exit gate:** Property tests prove per-asset zero-sum entries, non-negative user balance, exact rounding, replay safety, and legal approval transitions under concurrency.

## Phase 5: CAIBI Red Packets and Encrypted Business Cards

**Detailed plan output:** `docs/superpowers/plans/2026-08-12-red-packet-implementation.md`

**Files:**
- Create: `services/business-api/app/modules/redpacket/`
- Create: `packages/event-schemas/m.room.starchat.red_packet.v1.json`
- Create: `tests/business_api/redpacket/`

**Interfaces produced:**
- `RedPacketService.create_equal()` and `create_random()`
- `RedPacketService.claim()`, `expire()`, and `cancel_unclaimed()`
- E2EE card schema containing an opaque `red_packet_id`, schema version, and safe display hints

**Exit gate:** 100-way concurrent claim tests never duplicate a share; every allocation sums exactly to total; 24-hour expiry and authorized cancellation refund only unclaimed shares.

## Phase 6: Sandbox USDT-TRC20 Wallet and Reconciliation

**Detailed plan output:** `docs/superpowers/plans/2026-08-12-usdt-wallet-implementation.md`

**Files:**
- Create: `services/business-api/app/modules/wallet/`
- Create: `services/business-api/app/modules/wallet/AGENTS.md`
- Create: `services/business-api/app/integrations/custody/base.py`
- Create: `services/business-api/app/integrations/custody/sandbox.py`
- Create: `services/business-worker/app/tasks/wallet.py`
- Create: `tests/business_api/wallet/`

**Interfaces produced:** `CustodyProvider`, deposit state machine, withdrawal state machine, signed webhook intake, hourly incremental reconciliation, and daily full reconciliation.

**Exit gate:** Duplicate/out-of-order webhooks cannot duplicate credit; unknown withdrawal results query the original client order; reconciliation mismatch pauses automatic withdrawals.

## Phase 7: Flutter Android/iOS, Matrix E2EE, and Business Features

**Detailed plan output:** `docs/superpowers/plans/2026-08-12-flutter-client-implementation.md`

**Files:**
- Create: `apps/mobile_flutter/`
- Create: `apps/mobile_flutter/AGENTS.md`
- Generate: `packages/api-contracts/dart/`
- Create: `tests/mobile/`

**Interfaces produced:** Secure auth/session storage, Matrix sync, cross-signing, encrypted key backup, encrypted text/media/voice messages, support UI, CAIBI transfer/red packet cards, wallet UI, generic push payload handling, APK and TestFlight build pipelines.

**Exit gate:** A fresh user registers without phone/real name, verifies email, saves a recovery key, logs into two verified devices, exchanges E2EE content, and completes all Sandbox business flows on Android and iOS.

## Phase 8: One-to-One Encrypted Voice and Video Calls

**Detailed plan output:** `docs/superpowers/plans/2026-08-12-encrypted-calls-implementation.md`

**Files:**
- Extend: `apps/mobile_flutter/lib/features/calls/`
- Create: `infra/turn/`
- Create: `tests/calls/`

**Interfaces produced:** E2EE Matrix call signaling, WebRTC media, TURN/SFU configuration, call metadata events, permission handling, reconnection, and no-recording enforcement.

**Exit gate:** Android-to-iOS and iOS-to-Android encrypted audio/video calls succeed on LAN, cellular, NAT, weak network, and reconnect scenarios; relays cannot decode media.

## Phase 9: React Administration Application

**Detailed plan output:** `docs/superpowers/plans/2026-08-12-admin-web-implementation.md`

**Files:**
- Create: `apps/admin_web/`
- Create: `apps/admin_web/AGENTS.md`
- Generate: `packages/api-contracts/typescript/`
- Create: `tests/admin_web/`

**Interfaces produced:** Invitation/user management, support queue, RBAC, adjustment approval, ledger search/reversal, red-packet cancellation, wallet approval/reconciliation, TOTP, and audit views.

**Exit gate:** Permission tests prove each role can perform only its approved actions; the application has no endpoint for reading normal E2EE room contents.

## Phase 10: Production Provider, Hardening, and Release

**Detailed plan output:** `docs/superpowers/plans/2026-08-12-production-readiness-implementation.md`

**Files:**
- Create: `services/business-api/app/integrations/custody/production.py`
- Create: `infra/production/`
- Create: `docs/runbooks/`
- Create: `tests/performance/`
- Create: `tests/disaster_recovery/`

**Produces:** Provider contract conformance, locked images, observability, backup/restore, reconciliation and custody incident runbooks, 50 TPS ledger and 500-member room evidence, controlled APK, and TestFlight artifact.

**Exit gate:** All functional, security, engineering, capacity, migration, backup/restore, and incident-response acceptance criteria in the approved design spec pass with recorded evidence.

## Cross-Phase Change Control

- Each phase receives a detailed TDD plan before code changes.
- OpenAPI changes land before generated clients and must include compatibility tests.
- Ledger schema/formula, red-packet allocation, wallet state machine, E2EE/key recovery, auth/RBAC/TOTP, and destructive migrations require an ADR and dual review.
- A phase is not complete until its exit gate passes from a clean environment.
- If a phase changes an approved invariant, stop execution and return to design approval rather than silently adapting the implementation.
