# Registration Verification and Server Activation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record the configured SSH deployment target, provide a one-time 30-day activation-code command, and update the Flutter registration form with email verification code, password visibility, confirmation validation, and the approved grouped layout.

**Architecture:** Activation codes are created through the existing `InvitationService` and persisted as hashes in the business database. The Flutter page remains a presentation layer over `RegistrationController`; client-side checks prevent avoidable submissions while the Business API remains authoritative.

**Tech Stack:** PowerShell 7, Python 3.12, SQLAlchemy, Docker Compose, Flutter/Dart, flutter_test, Cupertino widgets.

---

### Task 1: Record deployment target and activation-code command

**Files:**
- Modify: `AGENTS.md`
- Create: `scripts/generate_invitation.py`
- Create: `docs/runbooks/activation-codes.md`
- Test: `tests/business_api/identity/test_invitation_generation_script.py`

- [x] **Step 1: Write the failing test** asserting the command generates a cryptographically random code, uses `max_uses=1`, and sets expiry 30 days from the clock.
- [x] **Step 2: Run the focused test and confirm RED** because the script does not exist.
- [x] **Step 3: Implement the script** with explicit environment/database loading, `InvitationService.issue`, a random URL-safe code, and a single redacted status line containing the code and expiry.
- [x] **Step 4: Document the Docker command** using `docker compose exec business-api python -m app.cli.generate_invitation`; include a PowerShell equivalent and a status validation command.
- [x] **Step 5: Add the SSH host/port/user to `AGENTS.md`** without storing private keys or tokens.
- [x] **Step 6: Run the focused Python test and syntax check.**

### Task 2: Extend registration controller contract

**Files:**
- Modify: `apps/mobile_flutter/lib/features/auth/registration_controller.dart`
- Modify: `apps/mobile_flutter/test/features/auth/registration_controller_test.dart`

- [x] **Step 1: Add failing tests** for a required email verification code and mismatched password confirmation being rejected without calling the gateway.
- [x] **Step 2: Run those tests and verify RED.**
- [x] **Step 3: Add the registration-page verification-code carry-through**, preserve the existing backend registration call, and validate password confirmation before submission.
- [x] **Step 4: Run controller tests and verify GREEN.**

### Task 3: Implement grouped registration UI

**Files:**
- Modify: `apps/mobile_flutter/lib/ui/components/auth_surface_card.dart`
- Modify: `apps/mobile_flutter/lib/features/auth/registration_page.dart`
- Modify: `apps/mobile_flutter/test/features/auth/auth_pages_test.dart`

- [x] **Step 1: Add failing widget tests** for six fields, both password visibility buttons, confirmation mismatch feedback, and email-code input.
- [x] **Step 2: Run the widget tests and verify RED.**
- [x] **Step 3: Add a reusable trailing visibility action to `AuthTextField`**, then implement the grouped labels and fields in the approved order while preserving existing tokens/buttons.
- [x] **Step 4: Wire submit to controller validation and display inline field errors.**
- [x] **Step 5: Run focused Flutter auth tests and verify GREEN.**

### Task 4: Verification evidence and regression checks

**Files:**
- Create: `docs/verification/2026-08-19-registration-server-activation.md`

- [x] **Step 1: Run focused Flutter tests, Python tests, and `scripts/verify.ps1` when available.**
- [x] **Step 2: Record exact commands, exit statuses, and relevant outputs without secrets.**
- [x] **Step 3: Run a specification/security review for invitation hashing, one-use expiry, password boundaries, and E2EE invariants.**
