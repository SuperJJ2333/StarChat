# Matrix History Recovery and Unread Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore locally unavailable Megolm inbound sessions without exposing secrets and display the total message unread count on the bottom navigation icon.

**Architecture:** A session-scoped recovery coordinator depends only on a Matrix recovery backend; the SDK adapter restores online backup sessions after a locally held recovery key unlocks SSSS and uploads inbound sessions after sync. The unread total is queried through the existing Matrix conversation capability and rendered in a size-constrained tab icon badge.

**Tech Stack:** Flutter/Dart, matrix 0.34.0, SQLCipher, flutter_secure_storage, Flutter widget tests.

---

### Task 1: Recovery coordinator

**Files:** create `apps/mobile_flutter/lib/features/matrix/matrix_recovery_service.dart`; create `apps/mobile_flutter/test/features/matrix/matrix_recovery_service_test.dart`.

- [ ] Write RED tests for no-key state, restore path, public-key mismatch, and idempotent upload.
- [ ] Implement an adapter-only coordinator that never accepts Business API access and never wipes local Matrix state.
- [ ] Run focused tests and commit.

### Task 2: SDK restore lifecycle

**Files:** modify `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart`; modify `apps/mobile_flutter/lib/main.dart`.

- [ ] Add RED coverage for a locally stored recovery key opening SSSS then loading inbound sessions.
- [ ] Implement key-backup bootstrap/unlock/restore and post-sync upload through the SDK client only.
- [ ] Run focused tests and commit.

### Task 3: Unread badge

**Files:** modify `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart`; modify `apps/mobile_flutter/lib/app_home.dart`; create `apps/mobile_flutter/test/app_home_unread_badge_test.dart`.

- [ ] Write RED widget tests for 0, 12, 99+ and live refresh.
- [ ] Implement total unread capability and adaptive red badge around both active/inactive message icons.
- [ ] Run widget and full Flutter tests, then build/install on both emulators.
