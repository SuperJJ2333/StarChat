# Contacts & Friend and Conversation Operations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the complete Contacts & Friend workflow, API-authoritative duplicate friend-request prevention with record reuse, and WeChat-style long-press conversation operations.

**Architecture:** Friendship state remains authoritative in the FastAPI business API and PostgreSQL. Matrix remains authoritative only for encrypted room communication and per-room local conversation preferences; Flutter never sends message plaintext or derived chat state to the business API. The client performs optimistic UI guards but always renders API relationship/error results.

**Tech Stack:** FastAPI, SQLAlchemy 2, Alembic, PostgreSQL, Pydantic, Flutter/Dart Cupertino widgets, Matrix Dart SDK, flutter_test.

---

## File ownership map

- Backend friendship model/service/API: `services/business-api/app/modules/friendship/models.py`, `services/business-api/app/modules/friendship/service.py`, `services/business-api/app/api/friendship.py`.
- Backend migration and contract: `services/business-api/migrations/versions/0020_friend_request_reuse.py`, `packages/api-contracts/openapi/liuhetong-v1.yaml`.
- Backend tests: `tests/business_api/friendship/test_friendship_api.py`.
- Flutter API/domain: `apps/mobile_flutter/lib/core/business_api_client.dart`, `apps/mobile_flutter/lib/features/contacts/contact_models.dart`.
- Flutter Contacts UI: `apps/mobile_flutter/lib/features/contacts/contacts_page.dart`, `apps/mobile_flutter/lib/features/contacts/contact_profile_sections.dart`.
- Flutter conversation state/UI: `apps/mobile_flutter/lib/features/matrix/conversation_preferences.dart`, `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`, `apps/mobile_flutter/lib/ui/components/conversation_list_tile.dart`, plus new `apps/mobile_flutter/lib/ui/chat/conversation_action_sheet.dart`.
- Flutter tests: `apps/mobile_flutter/test/features/contacts/contact_flow_test.dart`, new `apps/mobile_flutter/test/features/contacts/friend_request_duplicate_test.dart`, new `apps/mobile_flutter/test/features/matrix/conversation_actions_test.dart`, new `apps/mobile_flutter/test/ui/conversation_action_sheet_test.dart`.
- Evidence: `docs/verification/2026-08-21-contacts-friend-conversation-operations.md` and `docs/verification/artifacts/2026-08-21/contacts-friend-design/`.

### Task 1: Backend red tests for authoritative friend-request rules

**Files:** `tests/business_api/friendship/test_friendship_api.py`.

- [ ] Add a failing test that sends two requests with different idempotency keys while the first is `PENDING`; assert HTTP 409, code `FRIEND_REQUEST_DUPLICATE`, and message `不能重复发送好友请求`.
- [ ] Add a failing test that accepts a request and then attempts another request in the opposite direction; assert the same 409 response.
- [ ] Add a failing test that rejects a request, resubmits with a new key/message, and asserts the same request `id`, status `PENDING`, changed message, and a later `requested_at`.
- [ ] Add a failing expired-row reuse test by setting the existing row to `EXPIRED`; assert ID reuse and cleared `resolved_at`.
- [ ] Add a failing projection test asserting request list includes `requested_at` and search returns relationship states `NONE`, `OUTGOING_PENDING`, `FRIEND`, or `REUSABLE`.
- [ ] Run `pwsh -NoProfile -Command "$env:PYTHONUTF8='1'; $env:PYTHONIOENCODING='utf-8'; pytest tests/business_api/friendship/test_friendship_api.py -q"`; record the intentional failures under `docs/verification/artifacts/2026-08-21/contacts-friend-design/backend-red.txt`.

### Task 2: Implement model, migration, and service-level race protection

**Files:** `services/business-api/app/modules/friendship/models.py`, `services/business-api/migrations/versions/0020_friend_request_reuse.py`, `services/business-api/app/modules/friendship/service.py`.

- [ ] Add non-null `requested_at` to `FriendRequest`; preserve immutable `created_at` and existing idempotency uniqueness.
- [ ] Create migration `0020_friend_request_reuse` after `0019_matrix_profile_sync`: add nullable `requested_at`, backfill from `created_at`, make it non-null, add indexes for `(requester_id,target_id,status,requested_at)` and the pending pair lookup, and downgrade only these additive changes.
- [ ] In `FriendshipService.request`, keep idempotency replay behavior first; then lock/query the pair in either direction and reject an existing friendship with `FRIEND_REQUEST_DUPLICATE`.
- [ ] Reject an outgoing `PENDING` row with the same stable error; reuse the newest `REJECTED` or `EXPIRED` row by changing message, idempotency key, status, `requested_at`, and `resolved_at` in one transaction.
- [ ] Add a database-safe pending-pair uniqueness strategy compatible with PostgreSQL and SQLite tests; catch an integrity race and translate it to the stable duplicate error.
- [ ] Update audit/outbox actions for `friend.requested` and `friend.request.reused` without logging request text.
- [ ] Run the focused backend tests and confirm they pass.

### Task 3: Extend API and OpenAPI relationship projections

**Files:** `services/business-api/app/api/friendship.py`, `packages/api-contracts/openapi/liuhetong-v1.yaml`, `tests/business_api/friendship/test_friendship_api.py`.

- [ ] Return `requested_at` and all relevant received statuses from `GET /friends/requests`, ordered descending by latest request time while retaining projection privacy.
- [ ] Add relationship state to `GET /users/search` results using the service's business-domain lookup; do not consult Matrix.
- [ ] Document `FRIEND_REQUEST_DUPLICATE`, `requested_at`, relationship-state enum, and 409 responses in OpenAPI schemas and endpoint responses.
- [ ] Add contract assertions that generated response fields match the implementation.
- [ ] Run `pytest tests/business_api/friendship/test_friendship_api.py -q` and an OpenAPI parse/validation command used by the repository.

### Task 4: Flutter API client and domain models

**Files:** `apps/mobile_flutter/lib/core/business_api_client.dart`, `apps/mobile_flutter/lib/features/contacts/contact_models.dart`, new `apps/mobile_flutter/test/features/contacts/friend_request_duplicate_test.dart`.

- [ ] Add immutable `FriendRequestSummary` and `FriendRelationshipState` models with avatar, nickname, message, status, and `requestedAt` parsing.
- [ ] Add typed `friendRequestSummaries()` and search projection parsing while preserving existing gateway methods.
- [ ] Keep `requestFriend` idempotent; catch `BusinessApiException` with code `FRIEND_REQUEST_DUPLICATE` and expose a single UI message constant `不能重复发送好友请求`.
- [ ] Write client tests for pending/friend duplicate mapping, reusable rejected/expired response, and unrelated errors propagating unchanged.
- [ ] Run `flutter test test/features/contacts/friend_request_duplicate_test.dart` and `dart analyze` for changed files.

### Task 5: Redesign Contacts and New Friends UI

**Files:** `apps/mobile_flutter/lib/features/contacts/contacts_page.dart`, `apps/mobile_flutter/lib/features/contacts/contact_profile_sections.dart`, `apps/mobile_flutter/test/features/contacts/contact_flow_test.dart`.

- [ ] Add a stable `WeChatFriendRequestTile` with 68dp height, 48dp avatar, optional two-line verification message, 64×32dp state button, semantics labels, and text states `接受`, `已添加`, `已拒绝`, `已过期`.
- [ ] Refactor `FriendRequestsPage` to include back navigation, grouped status sections, in-place accept/reject state updates, authoritative refresh, and long-press reject action without introducing hard-coded colors or sizes.
- [ ] Update Contacts top rows to fixed order `新的朋友`, `群聊`, `标签`, `官方客服`, retain the 20dp A–Z index, and keep existing profile/settings/tag/group routes.
- [ ] Update Add Friend search results to render relationship state actions, verification-message entry, disabled duplicate states, and a `WeChatToast`/Cupertino feedback with the exact duplicate message.
- [ ] Extend widget tests at 393×852 and 360×640 for row order, all request states, avatar/verification text, semantics, overflow, and profile/settings navigation.
- [ ] Run focused contact tests and `flutter analyze`.

### Task 6: Conversation preference state for unread/hidden/delete

**Files:** `apps/mobile_flutter/lib/features/matrix/conversation_preferences.dart`, `apps/mobile_flutter/test/features/matrix/conversation_actions_test.dart`.

- [ ] Extend `ConversationPreference` content with `manual_unread`, `hidden`, and `hidden_at`, preserving unknown/unrelated account-data keys on writes.
- [ ] Add pure helpers `markUnread`, `clearUnreadOnOpen`, `hideConversation`, `restoreForIncomingEvent`, and `shouldRestoreHidden` (only a newer incoming event restores; own events do not).
- [ ] Add tests for codec round-trip, pin/unpin ordering for direct and group rooms, unread clear-on-open, hidden persistence, and incoming-only restoration.
- [ ] Run the focused Dart tests before integrating the UI.

### Task 7: Implement WeChat-style long-press conversation menu

**Files:** new `apps/mobile_flutter/lib/ui/chat/conversation_action_sheet.dart`, `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`, `apps/mobile_flutter/lib/ui/components/conversation_list_tile.dart`, `apps/mobile_flutter/test/ui/conversation_action_sheet_test.dart`.

- [ ] Define typed actions `markUnread`, `togglePin`, `hide`, and `delete` with icon, Chinese label, and semantic label; pin action toggles between `置顶该聊天` and `取消置顶`.
- [ ] Add `onLongPress` to every visible `ConversationListTile`; show a modal bottom action sheet with `scrim`, 12dp top corners, outside-tap dismissal, and reduced-motion behavior.
- [ ] Wire mark-unread and pin actions through `writeConversationPreference`; recalculate ordering immediately and clear manual unread when `_openRoom` succeeds.
- [ ] Wire hide to account data and visible-room filtering; observe sync/timeline updates and restore only for newer incoming events.
- [ ] Add delete confirmation titled `确定删除该聊天？` with `取消` and danger `删除`; invoke the existing public Matrix local-history/room-state clearing interface and remove only the selected conversation from this device's list.
- [ ] Add widget tests for menu labels/icons, animation-disabled mode, outside dismissal, pin toggle, unread badge, hidden removal/restoration, and confirmation text.
- [ ] Run focused Flutter tests and analyzer.

### Task 8: Full verification, specification review, and evidence

**Files:** `docs/verification/2026-08-21-contacts-friend-conversation-operations.md`, `docs/verification/artifacts/2026-08-21/contacts-friend-design/*`.

- [ ] Run backend formatting/lint/type checks and all friendship tests.
- [ ] Run `dart format --output=none --set-exit-if-changed` on changed Dart files, `flutter analyze`, focused tests, and the complete `flutter test` suite.
- [ ] Run `pwsh -NoProfile -File scripts/verify.ps1` when present.
- [ ] Perform a specification-compliance review covering API authority, idempotency, audit/outbox, Matrix E2EE boundaries, UI tokens, accessibility, and no plaintext leakage.
- [ ] Record exact commands, outputs, exit codes, migration revision, and changed files in the verification document; keep all temporary artifacts below `docs/verification/artifacts/2026-08-21/`.
- [ ] Run `git diff --check` and commit the implementation in small feature commits.

## Self-review

- API authority and reused rejected/expired records are covered by Tasks 1–3.
- Client-side validation and all Contacts/New Friends states are covered by Tasks 4–5.
- Unread, pin, hide, delete, confirmation, animation, and restoration semantics are covered by Tasks 6–7.
- Figma/plugin-specific node extraction remains pending until a node-specific Figma URL is supplied; implementation uses the repository's `UI_DESIGN.md` tokens and existing components rather than guessing a node.
- No task contains a placeholder, destructive migration, direct cross-module table write, or business-API access to Matrix plaintext.
