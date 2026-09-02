# ChatFlow Admin OpenAPI + RBAC Integration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace the dashboard fixture path with authenticated ChatFlow Admin API calls and server-enforced RBAC while preserving existing domain boundaries.

**Architecture:** FastAPI exposes `/api/v1/admin/session`, `/overview`, and module query endpoints. Route dependencies decode Bearer tokens and require declared `Permission` values through `RbacService`; services return redacted read models. The frontend uses a small same-origin OpenAPI client, stores short-lived access tokens in memory, gates actions by returned permissions, and handles 401/403 states.

**Tech Stack:** Python 3.12, FastAPI, SQLAlchemy, existing RBAC/TOTP/Audit/Idempotency services, vanilla ES modules in `design-demo`.

---

### Task 1: Admin API contracts and tests
**Files:** `services/business-api/app/api/admin.py`, `services/business-api/app/main.py`, `tests/business_api/admin/test_admin_api.py`, `scripts/export_openapi.py` output.
- [x] Write failing tests for session permissions, overview authorization, module permission denial, redacted fields, and administrator direct writes.
- [x] Run focused pytest and record expected failure.
- [x] Implement shared Bearer actor dependency, `GET /admin/session`, `GET /admin/overview`, and `GET /admin/modules/{module}` with explicit permission mapping and stable errors.
- [x] Register router and regenerate OpenAPI; run focused tests and contract drift test.

### Task 2: Frontend OpenAPI client and RBAC gate
**Files:** `design-demo/src/api/admin-client.js`, `design-demo/src/admin-home.js`, `design-demo/admin.html`, `design-demo/tests/admin-client.test.mjs`.
- [x] Write failing source tests for API URL, Authorization header, 401 handling, and permission gate.
- [x] Implement `AdminApiClient` with `session`, `overview`, `module`, and `request` methods; never persist tokens to localStorage.
- [x] Load session/overview on admin route, render loading/error/forbidden states, and use API data when authorized; keep fixture data only as explicit empty-state fallback.
- [x] Replace visible branding with “畅聊 ChatFlow”; retain internal slug compatibility.

### Task 3: Verification and review evidence
**Files:** `docs/verification/2026-08-27-chatflow-admin-rbac.md`, `docs/verification/artifacts/2026-08-27/chatflow-admin-rbac/*`.
- [x] Run focused backend tests, full pytest, OpenAPI drift, `npm test`, and browser smoke for admin/home routes.
- [x] Verify 401/403, role permissions, direct-administrator writes without TOTP/approval, idempotency, audit/Outbox hooks, and redaction behavior.
- [x] Record BASELINE/MODIFIED/ROLLBACK commands and outputs; test rollback on a copy.
- [x] Perform specification-compliance and Quality/Security review; update ADR if findings require changes.
