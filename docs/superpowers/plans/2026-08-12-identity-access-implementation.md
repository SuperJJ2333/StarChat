# 六合通 Phase 2 Identity and Access Implementation Plan

> **For agentic workers:** Execute task-by-task with TDD. Do not expose a route before its state machine, authorization, audit, and idempotency behavior are tested.

**Goal:** Implement username/password/invitation registration with mandatory email verification, Matrix account provisioning, rotating sessions, device management, RBAC, administrator TOTP enforcement, withdrawal security holds, and append-only audit records.

**Architecture:** Identity remains authoritative in the modular business backend. Matrix receives a linked user only after the business account has passed email verification. Registration uses `PENDING_EMAIL -> PENDING_MATRIX -> ACTIVE`; retries are idempotent. Passwords and opaque tokens are stored only as hashes. Audit rows are append-only and contain metadata rather than encrypted message content.

## Fixed rules

- Registration requires username, password, valid invitation code, and email.
- Phone number and real-name identity are not accepted registration fields.
- Email verification is mandatory before Matrix provisioning and activation.
- Roles: `USER`, `SUPPORT_AGENT`, `FINANCE_SUPPORT`, `SUPPORT_SUPERVISOR`, `SUPER_ADMIN`.
- Permissions are explicit and deny by default; roles never bypass service-level scope checks.
- Administrator-sensitive operations require a recently verified TOTP challenge.
- Refresh tokens rotate; reuse revokes the entire token family.
- Password reset revokes all sessions and applies a 24-hour withdrawal hold.
- Audit records are append-only and cannot contain secrets, password hashes, tokens, TOTP seeds, message plaintext, or plaintext attachments.
- Matrix provisioning must be idempotent and never activates the account before a stable Matrix user ID exists.

## Task 1: Identity domain models and migration

**Files:**
- Create `services/business-api/app/modules/identity/models.py`
- Create `services/business-api/app/modules/identity/enums.py`
- Create migration `0004_identity_foundation.py`
- Create `tests/business_api/identity/test_models.py`

Implement users, invitations, email-verification challenges, devices, refresh-token families/tokens, role assignments, TOTP credentials, and security holds. Add normalized unique indexes for username/email and immutable timestamps. Verify PostgreSQL migration upgrade/downgrade SQL.

## Task 2: Passwords, invitations, and email verification

**Files:**
- Create `identity/passwords.py`, `identity/invitations.py`, `identity/registration.py`
- Create `services/business-worker/app/tasks/email.py`
- Create focused tests under `tests/business_api/identity/`

Use Argon2id password hashes, cryptographically random opaque verification tokens stored as SHA-256 hashes, expiring/single-use invitations, retry-limited challenges, and generic responses that do not leak whether an email exists.

## Task 3: Matrix provisioning state machine

**Files:**
- Create `services/business-api/app/integrations/matrix_admin.py`
- Extend registration service and Outbox handlers
- Create contract and failure-recovery tests

Define `MatrixAdminGateway.ensure_user(localpart, password)` as idempotent. Verification commits `PENDING_MATRIX` plus Outbox in one transaction. Worker provisioning writes a stable Matrix user ID and activates the account. Failures remain retryable without duplicate Matrix users.

## Task 4: Access and refresh tokens, devices, password recovery

**Files:**
- Create `identity/tokens.py`, `identity/devices.py`, `identity/recovery.py`
- Create API routes and schemas
- Create replay/concurrency tests

Implement short-lived JWT access tokens and hashed opaque refresh tokens. Rotate on every refresh. Detect consumed-token replay and revoke the token family. Support device listing/revocation. Password recovery revokes all families and creates a 24-hour `WITHDRAWAL` hold.

## Task 5: RBAC and administrator TOTP

**Files:**
- Create `identity/rbac.py`, `identity/totp.py`
- Create authorization dependencies
- Create role/permission and TOTP replay tests

Permissions cover support assignment, finance review, supervisor approval, user scope management, audit viewing, and system administration. Store encrypted TOTP seeds through a key-provider interface. Prevent OTP replay inside the accepted time window and require TOTP for privileged administrator mutations.

## Task 6: Append-only audit domain

**Files:**
- Create `services/business-api/app/modules/audit/`
- Create migration `0005_audit_events.py`
- Create `tests/business_api/audit/`

Implement `AuditWriter.record()` with actor, subject, action, result, reason code, trace ID, source IP/device, before/after safe metadata, and timestamp. Add database triggers that reject update/delete. Add secret-redaction tests.

## Task 7: Identity HTTP API and OpenAPI contract

**Routes:**
- `POST /api/v1/invitations/validate`
- `POST /api/v1/auth/register`
- `POST /api/v1/auth/verify-email`
- `POST /api/v1/auth/login`
- `POST /api/v1/auth/refresh`
- `POST /api/v1/auth/logout`
- `POST /api/v1/auth/password/forgot`
- `POST /api/v1/auth/password/reset`
- `GET /api/v1/devices`
- `DELETE /api/v1/devices/{device_id}`

All routes use stable errors, trace IDs, rate-limit hooks, and OpenAPI drift checks. Registration schemas reject phone and real-name fields rather than silently persisting them.

## Task 8: PostgreSQL/Redis integration, container validation, and verification

Run migrations against the Compose PostgreSQL service, exercise Redis-backed rate-limit/session revocation behavior, build images, start services, and verify liveness/readiness. Extend `scripts/verify.ps1`, export the OpenAPI contract, and write `docs/verification/phase-2/summary.md`.

## Phase 2 completion gate

No account becomes `ACTIVE` before email verification and Matrix provisioning. Invitation consumption and verification are replay-safe. Password reset revokes all sessions and creates the withdrawal hold. Refresh-token reuse revokes its family. RBAC denies unknown permissions. Privileged administrator mutations require TOTP. Audit records are append-only and secret-free. Unit, PostgreSQL integration, migration, OpenAPI, image build, and container health checks pass.
