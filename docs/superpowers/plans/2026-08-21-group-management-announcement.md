# Group Management and Announcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement fixed navigation bars and WeChat-style Matrix group-management, QR, announcement, member search and removal UI.

**Architecture:** Extend the existing `GroupChatInfoSnapshot`, gateway and controller with a versioned account-data group configuration. Keep Matrix room membership writes in the gateway and derive UI authorization from owner/admin IDs. Render reusable presentation pages from the controller snapshot.

**Tech Stack:** Flutter Cupertino, matrix Dart SDK, flutter_test.

---

### Task 1: Model and permissions

**Files:**
- Modify: `apps/mobile_flutter/lib/features/matrix/group_chat_info_controller.dart`
- Test: `apps/mobile_flutter/test/features/matrix/group_chat_info_test.dart`

- [ ] Write failing tests for role ordering, owner/admin visibility and three-admin cap.
- [ ] Implement group settings snapshot, account-data serialization and controller updates.
- [ ] Run `flutter test test/features/matrix/group_chat_info_test.dart`.

### Task 2: Group information and member management UI

**Files:**
- Modify: `apps/mobile_flutter/lib/features/matrix/group_chat_info_page.dart`
- Test: `apps/mobile_flutter/test/features/matrix/group_chat_info_test.dart`

- [ ] Write failing widget tests for search icon, QR/management rows and role-dependent minus cell.
- [ ] Implement member search, remove selection/confirmation, QR and management pages.
- [ ] Run focused widget tests.

### Task 3: Announcement presentation

**Files:**
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`
- Test: `apps/mobile_flutter/test/features/matrix/room_page_presentation_test.dart`

- [ ] Write failing tests for announcement visibility/read state.
- [ ] Implement announcement bar and full announcement page.
- [ ] Run focused tests and analyzer.

### Task 4: Navigation and package verification

**Files:**
- Modify: relevant navigation bar owners under `apps/mobile_flutter/lib/`
- Modify: `UI_DESIGN.md`
- Modify: `docs/verification/2026-08-21-avatar-repository-remediation.md`

- [ ] Apply the fixed navigation token to all navigation bars.
- [ ] Run focused test suite, build debug APK, install and launch on `emulator-5554`.
