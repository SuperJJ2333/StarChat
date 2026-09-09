# Admin Console Modernization Implementation Plan

> Use subagent-driven-development for independent tasks, then specification and quality/security reviews.

**Goal:** Implement the seven improvements approved by the user on 2026-09-08.
**Architecture:** Independent server-enforced admin sessions; ledger-derived read-only reporting; existing HTML admin shell with focused reusable UI modules.
**Tech Stack:** FastAPI, SQLAlchemy, PostgreSQL, native JavaScript/CSS, node:test, pytest.

Approved source: `docs/superpowers/specs/2026-09-08-admin-console-modernization-design.md`; ADR-0059 approved by the same user confirmation. No destructive financial changes.

## Task 1 — Admin sessions (identity owner)
- [x] Add tests in `tests/business_api/identity_access/` for 48-hour absolute expiry, session replacement, refresh replay, normal-session isolation and recent-auth.
- [x] Run new tests red and record under `docs/verification/artifacts/2026-09-08/admin-modernization/`.
- [x] Implement identity models/service, identity endpoints, migration and admin-route enforcement. Use dedicated management refresh Cookie, origin checks and no-store; never expose refresh tokens to frontend persistence.
- [x] Verify failed logins leave prior session intact, concurrent successful logins leave only one session, ordinary tokens cannot bypass management enforcement.
- [x] Run focused green tests and report API contract to frontend owner.

## Task 2 — Dashboard reports (statistics owner)
- [x] Add red tests covering Hong Kong day boundaries and missing days; CAIBI issuance, reversal, escrow, fees and exact large decimal strings.
- [x] Implement read-only reporting through public query interfaces, update `api/admin.py`, paginated issuance/audit linkage and OpenAPI reporting contracts.
- [x] Query one consistent snapshot; distinguish accounting mismatch from zero. Never change ledger writes, historical entries or reserve formula.
- [x] Run focused green tests and report JSON shapes to frontend owner.

## Task 3 — UI and integration (root owner)
- [x] Add browser/Node tests for fixed sidebar, state-aware funding controls, refresh coordination, trend data and exact decimal formatting.
- [x] Implement focused modules alongside `admin-home.js`, update `admin-api.js`, `admin-login.js`, `admin-manual-wallet-panel.js` and admin styles.
- [x] Add memory access-token manager, Cookie-based bootstrap/refresh, cross-tab refresh lock, replacement handling and step-up without losing drafts.
- [x] Verify no mutation replay, stale-response overwrite or refresh-induced form reset.
- [x] Update UI registry/export evidence, respecting actual remote Figma availability and existing explicitly approved deferral scope.

## Task 4 — Reviews and delivery
- [x] Review spec compliance, then domain and quality/security; resolve findings.
- [x] Run frontend tests, targeted backend tests, UI contract verifier and `pwsh -NoProfile -File scripts/verify.ps1`.
- [x] Record exact commands, outputs, browser screenshots and limitations in `docs/verification/2026-09-08-admin-console-modernization.md`.
- [x] Prepare compatible migration/release and rollback documentation, preserving revoked sessions and financial state.

Test commands use project runtime discovery and UTF-8 PowerShell; Python has `PYTHONUTF8=1`, `PYTHONIOENCODING=utf-8`. Only this task's files are owned; pre-existing working-tree changes are neither reset nor committed incidentally.
