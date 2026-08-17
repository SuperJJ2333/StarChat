# Group Avatar, Pinned Conversations, and Chat Info Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement WeChat-style group avatar mosaics, stable pinned-group ordering, unified group/direct chat-info pages, mute exceptions, and local classified history search while preserving Matrix E2EE boundaries.

**Architecture:** Keep personal conversation preferences in Matrix per-room account data and isolate pure ordering/avatar/notification/search rules into small Dart units. Matrix room membership and already-decrypted local timeline data are the only communication-domain inputs; business APIs never receive message plaintext or derived search indexes.

**Tech Stack:** Flutter 3.44, Dart 3.12, matrix 0.34, flutter_test, Cupertino widgets, Figma Plugin API.

---

## File map

- Create `apps/mobile_flutter/lib/ui/chat/group_avatar_mosaic.dart`: fixed-shape 1–9 member mosaic layout.
- Create `apps/mobile_flutter/lib/features/matrix/conversation_preferences.dart`: model, Matrix gateway, migration, and stable conversation ordering.
- Create `apps/mobile_flutter/lib/features/matrix/direct_chat_info_page.dart`: private-chat information screen and add-member group creation flow.
- Create `apps/mobile_flutter/lib/features/matrix/mute_exception_policy.dart`: pure local notification decision rules.
- Create `apps/mobile_flutter/lib/features/matrix/chat_history_search.dart`: local decrypted entry categorization and filters.
- Modify `apps/mobile_flutter/lib/features/matrix/group_chat_info_controller.dart`: expanded settings and stable member list.
- Modify `apps/mobile_flutter/lib/features/matrix/group_chat_info_page.dart`: approved nested mute settings and classified search routes.
- Modify `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`: sorted room projections, group avatar rendering, unified info routing, simplified navigation.
- Modify `apps/mobile_flutter/lib/ui/components/conversation_list_tile.dart`: semantic pinned background option.
- Add focused tests under `apps/mobile_flutter/test/features/matrix/` and `apps/mobile_flutter/test/ui/`.
- Add Figma frames to file `zpzwTbnj1hqx80tyRygX78` under `20 Messages & Chat`.
- Record evidence in `docs/verification/2026-08-18-group-avatar-pinned-chat-info.md` and `docs/verification/artifacts/group-chat-v2/`.

### Task 1: Group avatar layout

**Files:**
- Create: `apps/mobile_flutter/lib/ui/chat/group_avatar_mosaic.dart`
- Create: `apps/mobile_flutter/test/ui/group_avatar_mosaic_test.dart`

- [ ] **Step 1: Write failing layout tests**

Test a pure `GroupAvatarLayout.rowsForCount` API for `1`, `3`, `5`, `6`, `7`, `8`, `9`, and `12`, and a widget test asserting every `group-avatar-member-*` slot has equal width, height, and corner radius.

```dart
expect(GroupAvatarLayout.rowsForCount(5), [2, 3]);
expect(GroupAvatarLayout.rowsForCount(7), [2, 2, 3]);
expect(GroupAvatarLayout.rowsForCount(12), [3, 3, 3]);
```

- [ ] **Step 2: Verify RED**

Run:

```powershell
flutter test test/ui/group_avatar_mosaic_test.dart
```

Expected: FAIL because `group_avatar_mosaic.dart` and `GroupAvatarLayout` do not exist.

- [ ] **Step 3: Implement the fixed-shape mosaic**

Implement exact row tables and render each row with centered `Row(mainAxisSize: MainAxisSize.min)`. Each avatar uses the same `SizedBox.square` and `ClipRRect`; never resize individual cells to fill a row.

- [ ] **Step 4: Verify GREEN**

Run the focused test and expect all cases to pass.

### Task 2: Conversation preferences and stable ordering

**Files:**
- Create: `apps/mobile_flutter/lib/features/matrix/conversation_preferences.dart`
- Create: `apps/mobile_flutter/test/features/matrix/conversation_preferences_test.dart`
- Modify: `apps/mobile_flutter/lib/ui/components/conversation_list_tile.dart`
- Modify: `apps/mobile_flutter/test/ui/messaging_surfaces_test.dart`

- [ ] **Step 1: Write failing preference and ordering tests**

Cover legacy `pinned=true` migration, `pinnedAt`, new-message stability, unpin/re-pin placement, group-only pinned surface, and fallback ordering.

```dart
expect(orderConversations([laterPinned, earlierPinned]), [earlierPinned, laterPinned]);
expect(orderConversations([earlierPinned.copyWith(lastActivity: newest), laterPinned]),
    [earlierPinned.copyWith(lastActivity: newest), laterPinned]);
```

- [ ] **Step 2: Verify RED**

Run the two focused test files. Expected: missing preference model/order function and missing `pinnedGroup` tile property.

- [ ] **Step 3: Implement repository, migration, and tile surface**

Use per-room account data type `com.liuhetong.conversation.settings.v2`. When pinning false→true, write an ISO-8601 UTC `pinned_at`; when unpinning clear it. Preserve other settings during writes. Sort pinned groups by timestamp ascending, then room ID; sort remaining rooms by last activity descending. Bind pinned group tiles to `WeChatColors.navigationSurface(context)` and ordinary tiles to `elevatedSurface`.

- [ ] **Step 4: Verify GREEN**

Run focused tests and expect pass.

### Task 3: Group and direct chat-info state

**Files:**
- Modify: `apps/mobile_flutter/lib/features/matrix/group_chat_info_controller.dart`
- Create: `apps/mobile_flutter/lib/features/matrix/direct_chat_info_page.dart`
- Modify: `apps/mobile_flutter/test/features/matrix/group_chat_info_test.dart`
- Create: `apps/mobile_flutter/test/features/matrix/direct_chat_info_test.dart`

- [ ] **Step 1: Write failing model/controller tests**

Add `folded`, `notifyMentionMe`, `notifyMentionAll`, `notifyAnnouncement`, and `followedMemberIds`. Assert only four followed IDs survive validation and departed members are removed. Assert direct info contains peer/add/search/mute/pin/save/clear and omits group-only rows.

- [ ] **Step 2: Verify RED**

Run both tests. Expected: constructor/property errors and missing direct page.

- [ ] **Step 3: Implement shared preference-backed state**

Extend the group snapshot/gateway without overwriting unrelated keys. Implement a direct info controller/page using the same conversation preference repository. The direct add action preselects the peer and requires at least one additional friend before invoking the existing group creation service.

- [ ] **Step 4: Verify GREEN**

Run focused tests and expect pass.

### Task 4: Mute exception hierarchy and policy

**Files:**
- Create: `apps/mobile_flutter/lib/features/matrix/mute_exception_policy.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/group_chat_info_page.dart`
- Create: `apps/mobile_flutter/test/features/matrix/mute_exception_policy_test.dart`
- Modify: `apps/mobile_flutter/test/features/matrix/group_chat_info_test.dart`

- [ ] **Step 1: Write failing policy and widget tests**

Assert: normal chat notifies; muted ordinary message does not; enabled `@me`, `@all`, announcement, or followed-sender events notify; disabled exceptions do not. Widget tests assert child rows are hidden when mute is off, visible when on, the detail route exposes four settings, and selection stops at four.

- [ ] **Step 2: Verify RED**

Expected: missing policy types and missing nested pages.

- [ ] **Step 3: Implement pure evaluation and pages**

Define `MuteEventFacts` and `MuteExceptionSettings`; return `normal`, `exception`, or `suppressed`. Render `折叠该聊天` and `以下消息仍通知` only while muted. Add detail and followed-member picker pages, filtering to joined non-self members and enforcing a four-ID maximum.

- [ ] **Step 4: Verify GREEN**

Run focused tests and expect pass.

### Task 5: Classified local history search

**Files:**
- Create: `apps/mobile_flutter/lib/features/matrix/chat_history_search.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/group_chat_info_page.dart`
- Create: `apps/mobile_flutter/test/features/matrix/chat_history_search_test.dart`
- Modify: `apps/mobile_flutter/test/features/matrix/group_chat_info_test.dart`

- [ ] **Step 1: Write failing search tests**

Cover keyword, date, image/video, file, URL, and sender filters. Assert direct mode has four categories and group mode has five. Assert no gateway accepts a business API or remote search callback.

- [ ] **Step 2: Verify RED**

Expected: missing entry/category/index types and old search page layout.

- [ ] **Step 3: Implement local-only search**

Build immutable `LocalChatSearchEntry` values from decrypted timeline view models. Classify with event kind, MIME type, timestamp, sender ID, and a local URL matcher. Update `ChatHistorySearchPage` to show top search field, category grid, filtered results, and group-member category only for group rooms.

- [ ] **Step 4: Verify GREEN**

Run focused tests and expect pass.

### Task 6: Messages and room integration

**Files:**
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`
- Modify: `apps/mobile_flutter/test/features/matrix/group_chat_info_test.dart`
- Create: `apps/mobile_flutter/test/features/matrix/matrix_home_conversation_test.dart`

- [ ] **Step 1: Write failing integration widget tests**

Assert group rooms render `GroupAvatarMosaic`; room list uses stable sorted projections; pinned groups use pinned surface; both direct and group room nav bars omit `chat-voice-call` and `chat-video-call`; `chat-details` pushes the appropriate chat-info page.

- [ ] **Step 2: Verify RED**

Expected: current room list uses SDK order/single avatar and direct details still use the action sheet.

- [ ] **Step 3: Integrate public interfaces**

Load preference projections without exposing control rooms. Use group joined members for mosaics, preserve private avatars, remove nav call buttons, and route direct rooms to `DirectChatInfoPage`. Keep call actions in the composer more panel.

- [ ] **Step 4: Verify GREEN**

Run focused tests and expect pass.

### Task 7: Figma strict-node update

**Files:**
- Update Figma file: `zpzwTbnj1hqx80tyRygX78`
- Create evidence: `docs/verification/artifacts/group-chat-v2/*.png`

- [ ] **Step 1: Read original design context**

Call `get_design_context` for the existing `20 Messages & Chat` gallery and current group-info frames with `skillNames=figma-design-to-code`; reuse exact colors, typography, spacing, and icons.

- [ ] **Step 2: Add/update independent frames**

Using `use_figma` with `figma-use,figma-generate-design`, add group avatar 1–9 variants, pinned message state, direct/group simplified nav, mute off/on, exception settings, four-member maximum, direct info, and group/direct classified search frames.

- [ ] **Step 3: Validate design**

Programmatically audit every new frame for `393 × 852`, allowed fonts, and overflow. Capture screenshots and visually inspect the contact sheet.

### Task 8: Full verification and simulator install

**Files:**
- Create: `docs/verification/2026-08-18-group-avatar-pinned-chat-info.md`

- [ ] **Step 1: Run formatting, analysis, and Flutter tests**

```powershell
dart format lib test
flutter analyze
flutter test
```

Expected: formatting stable, no analyzer issues, all tests pass.

- [ ] **Step 2: Run repository verification**

```powershell
pwsh -NoProfile -File scripts/verify.ps1
```

Expected: `Verification: PASS`.

- [ ] **Step 3: Build and install**

```powershell
flutter build apk --debug
adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-debug.apk
```

Expected: APK build succeeds and ADB returns `Success`.

- [ ] **Step 4: Record evidence and commit**

Record RED/GREEN outputs, Figma node IDs, APK size, package version, install timestamp, and simulator screenshot. Run `git diff --check`, then commit the implementation on local `main`.

