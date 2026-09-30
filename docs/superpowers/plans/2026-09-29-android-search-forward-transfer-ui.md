# Android 2191 Search, Forward Avatar, and Owner Transfer UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the unwanted local-search warning, display current room and friend avatars in search and forwarding, and finish a confirmed group-owner transfer on the group-info page with one toast.

**Architecture:** Local search coverage remains an internal truth; this work changes only its presentation. Global-search avatars resolve at paint time from a current Matrix room snapshot and account-scoped identity cache instead of persisting mutable media URLs in the message index. Shared mosaic geometry handles safe-area padding, while the transfer picker owns its selection and returns a one-time completion result through the existing navigation stack.

**Tech Stack:** Flutter/Dart, vendored Matrix SDK, `ProfileRepository`, Flutter widget tests, Node HTML demo, shared ChatFlow tokens and registry. No Business API, Matrix encryption, or financial-write changes.

---

## Baseline, file map, and ownership

Use the existing `codex/chat-search-jank` worktree at `C:/Users/Administrator/.codex/worktrees/chat-search-jank/StarChat`; Android 0.4.22+2191 is the installed **baseline**, not the output of this plan. Read `AGENTS.md`, `apps/mobile_flutter/AGENTS.md`, `docs/runbooks/mobile-delivery-workflow.md`, `docs/workflow/current-state.md`, the approved [design](../specs/2026-09-29-android-search-forward-transfer-ui-design.md), and `docs/runbooks/android-apk-rebuild.md` before implementation. Confirm the current branch, `git status --short`, available simulator, Flutter SDK, and existing verification evidence before running a long gate. At the start of each PowerShell 7 session set:

```powershell
$u = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $u; [Console]::OutputEncoding = $u; $OutputEncoding = $u
$env:PYTHONUTF8 = '1'; $env:PYTHONIOENCODING = 'utf-8'
```

| Owner | Files | Responsibility |
| --- | --- | --- |
| Room search UI | `apps/mobile_flutter/lib/ui/chat/chat_search_page.dart`; `apps/mobile_flutter/test/ui/chat/chat_search_feedback_test.dart` | Remove two warning branches without changing coverage semantics. |
| Global-search avatars | `apps/mobile_flutter/lib/features/search/global_search_models.dart`, `global_search_page.dart`, new `global_search_avatar.dart`; `apps/mobile_flutter/test/features/search/global_search_page_test.dart`, new `global_search_avatar_test.dart` | Map current room identity/Matrix media to 40dp search avatars, including historical conversation rows. |
| Forward layout | `apps/mobile_flutter/lib/ui/chat/group_avatar_mosaic.dart`, `chat_forward_picker_page.dart`; `apps/mobile_flutter/test/ui/group_avatar_mosaic_test.dart`, `chat_forward_picker_page_test.dart` | Remove inherited safe-area padding and fit the existing candidate widget into each picker's own square slot. No `room_page.dart` edit. |
| Group owner transfer | `apps/mobile_flutter/lib/features/matrix/group_chat_info_page.dart`; `apps/mobile_flutter/test/features/matrix/group_chat_info_test.dart` | Search joined members, show real 40dp avatars, and propagate authoritative completion to group info. Keep controller, API and Matrix write behavior unchanged. |
| HTML demo module | `frontend/src/screens/messaging.js`; new `frontend/tests/android-search-forward-transfer-demo.test.mjs` | Search/forward/transfer visual states and interactions. |
| Root serial integration | `frontend/src/styles/primitives.css`, `frontend/src/catalog/screens.js`, `packages/ui-contracts/changliao-component-registry.json`, `docs/workflow/tasks/2026-09-29-android-2191-followup.md` | Apply shared CSS and register reviewable states after wallet and messaging screen changes, then maintain the component contract and task evidence. These shared files are reserved for root; other agents must not edit them. |

The media and wallet module owners have different files. No task in this plan edits `apps/mobile_flutter/lib/core/business_api_client.dart` or `apps/mobile_flutter/lib/features/matrix/room_page.dart`. Agents must not edit `group_chat_info_page.dart` concurrently with any other owner. All RED/GREEN logs belong under `docs/verification/artifacts/2026-09-29/android-2191-followup/` or a named child, never repository root.

## Task 1: Remove only the visible undecrypted-search warning

**Files:** Modify `apps/mobile_flutter/lib/ui/chat/chat_search_page.dart:432-496`; test `apps/mobile_flutter/test/ui/chat/chat_search_feedback_test.dart`. `LocalRoomHistorySearch.coverageIncomplete`, `ChatSearchResultPage.coverageIncomplete` and `PerformanceTrace.fullCoverageMs` stay intact.

- [ ] **Step 1: Write two failing widget cases.** Add one `searchBatch` returning a `ChatSearchSlice` with a text hit and `coverageIncomplete: true`, and one with no hits and the same flag. The key assertions are:

```dart
const oldWarning = '部分本地消息尚未解密，无法完整检索';
expect(find.text(oldWarning), findsNothing);
expect(find.byKey(const Key('chat-search-result-visible')), findsOneWidget);
// In the no-hit case:
expect(find.text('暂无匹配记录'), findsOneWidget);
expect(find.text(oldWarning), findsNothing);
```

Construct the hit as `ChatSearchMessage(eventId: 'visible', senderId: '@a:x', senderDisplayName: 'A', timestamp: DateTime(2026, 9, 29), timelineOrder: 1, visibleText: 'hello')`; enter `hello` in `chat-search-input` and pump past the 300ms debounce. The fake returns `const ChatSearchSlice(items: [], nextCursor: null, coverageIncomplete: true)` for the empty case. Add a controller-level assertion in `test/features/matrix/chat_search_query_controller_test.dart` only if the existing `local_room_history_search_test.dart` and `local_history_sdk_adapter_test.dart` no longer prove the flag remains true.

- [ ] **Step 2: Verify RED.** From `apps/mobile_flutter`, run `& 'C:/src/flutter/bin/flutter.bat' test --no-pub test/ui/chat/chat_search_feedback_test.dart`. Expected: the old warning appears for both cases; the neutral empty copy is absent.

- [ ] **Step 3: Make the presentation-only change.** Delete the `if (page.coverageIncomplete) _inlineStatus(...)` branch when results exist. Delete the terminal `if (page?.coverageIncomplete ?? false)` warning branch. Change only the final empty-state `Text` to `暂无匹配记录`; do not change search callbacks, filters, cursor, or the coverage flag.

```dart
return const Center(
  key: Key('chat-search-no-results'),
  child: Text('暂无匹配记录',
      style: TextStyle(fontSize: 14, color: WeChatColors.textSecondary)),
);
```

- [ ] **Step 4: Verify GREEN and commit.** Re-run the widget test and `test/features/matrix/local_room_history_search_test.dart test/features/matrix/local_history_sdk_adapter_test.dart`. Expected: the new UI tests pass and the existing incomplete-coverage assertions remain true. Commit only this UI file and its focused test.

## Task 2: Resolve global-search avatars from current room identity

**Files:** Modify `apps/mobile_flutter/lib/features/search/global_search_models.dart`, `global_search_page.dart`; create `apps/mobile_flutter/lib/features/search/global_search_avatar.dart`; test `apps/mobile_flutter/test/features/search/global_search_page_test.dart` and new `global_search_avatar_test.dart`. Use `WeChatDimensions.contactAvatar` (40dp); the main conversation list is 48dp and is not altered.

- [ ] **Step 1: Write RED mapping and widget tests.** In `global_search_page_test.dart`, inject a room list with (a) group `mxc` avatar, (b) group without a room avatar but two members with `mxc` avatars, and (c) direct room with a peer Matrix ID and avatar. Inject a message index hit whose `roomAvatarUrl` is null. Search each fixture and assert the group row and conversation row contain a 40dp `SearchRoomAvatar`, carry the expected Matrix URI, and choose `GroupAvatarMosaic` when the group has no room avatar. Assert both rows keep the same `roomId`/event anchor on tap. In `global_search_avatar_test.dart`, use a fake `AvatarMediaCapability` returning null and assert the widget still renders a stable fallback, does not request Business API data, and switches to the identity cache's current avatar URL after an identity change. Give `GlobalSearchPage` an optional `AvatarMediaCapability? avatarMedia` test seam; production resolves it as `widget.avatarMedia ?? widget.matrix`.

```dart
expect(tester.widget<MatrixUserAvatar>(
  find.descendant(of: find.byKey(const Key('global-search-room-!g:test')),
      matching: find.byType(MatrixUserAvatar))).matrixAvatarUri,
  Uri.parse('mxc://test/group'));
expect(tester.getSize(find.descendant(
  of: find.byKey(const Key('global-search-conversation-!g:test')),
  matching: find.byType(SearchRoomAvatar))).width, 40);
```

- [ ] **Step 2: Verify RED.** Run `& 'C:/src/flutter/bin/flutter.bat' test --no-pub test/features/search/global_search_page_test.dart test/features/search/global_search_avatar_test.dart`. Expected: `SearchRoomAvatar`/member metadata do not exist, and current search rows use URL-only `UserAvatar` in the 28dp default leading slot.

- [ ] **Step 3: Extend only typed display metadata.** Add an immutable `GlobalSearchAvatarMember` with `userId`, `displayName`, `matrixAvatarUri`, and add `directPeerId` plus `avatarMembers` (default empty) to `GlobalSearchRoomResult`. In `_roomsFromLocalSnapshot`, copy `room.avatar`, `room.directPeerId`, and up to nine `room.members` into those fields. In `_loadRooms`, keep a current-account map of visible room ID to the **whole** `GlobalSearchRoomResult` after visibility filtering; clear it when the widget's Matrix owner changes and on dispose. Do not put credentials, Matrix media URLs, or message plaintext into persistent global-search index rows.

```dart
GlobalSearchRoomResult(
  roomId: room.id,
  displayName: room.displayName,
  isDirect: room.isDirect,
  memberCount: room.members.isEmpty ? null : room.members.length,
  avatarSeed: room.id,
  matrixAvatarUri: room.avatar,
  directPeerId: room.directPeerId,
  avatarMembers: [
    for (final member in room.members.take(9))
      GlobalSearchAvatarMember(
        userId: member.id,
        displayName: member.displayName,
        matrixAvatarUri: member.avatar,
      ),
  ],
)
```

- [ ] **Step 4: Implement the focused `SearchRoomAvatar` renderer.** Give it a `GlobalSearchRoomResult`, optional `AvatarMediaCapability`, optional `ProfileRepository`, and `size`. A direct room resolves `directPeerId` through `ProfileRepository.resolveIdentity`; a group uses its `matrixAvatarUri` when present, else `GroupAvatarMosaic` of current joined members; no Matrix owner or zero members falls back to `UserAvatar`. Enter the `MatrixUserAvatar` branch only after `avatarMedia != null`; it receives `matrixAvatarUri` only when the business avatar is not authoritatively known, and receives `fallbackAvatarUrl` plus account-scoped `cacheKey`. Reuse `MatrixUserAvatar` and `GroupAvatarMosaic`, not a new image cache.

```dart
final identity = identityCache?.resolveIdentity(
    matrixUserId: room.directPeerId, displayName: room.displayName);
return MatrixUserAvatar(
  avatarMedia: avatarMedia!, // Only inside the non-null media branch.
  nickname: identity?.displayName ?? room.displayName,
  fallbackSeed: identity?.cacheKey ?? room.directPeerId ?? room.roomId,
  matrixAvatarUri:
      identity?.avatarIsKnown == true ? null : room.matrixAvatarUri,
  fallbackAvatarUrl: identity?.avatarUrl ?? room.avatarUrl,
  size: size,
);
```

- [ ] **Step 5: Connect rows and verify GREEN.** `_RoomRow` receives its current room metadata; `_ConversationRow` looks up `conversation.roomId` (the logical primary) in the current room map and falls back to `conversation.latest.room` only if absent. Pass `leadingSize: WeChatDimensions.contactAvatar` to search contact, room, conversation and detail-hit `WeChatListTile` rows; retain search result IDs and the source-room anchor for opening. Re-run the two tests plus `global_search_controller_test.dart global_search_persistence_test.dart`, and analyze the changed Dart files. Expected: group, direct, and historical hit avatars render at 40dp; no Business API search or navigation regression. Commit this task separately.

## Task 3: Remove safe-area drift in forwarding avatars

**Files:** Modify `apps/mobile_flutter/lib/ui/chat/group_avatar_mosaic.dart`, `chat_forward_picker_page.dart`; test `apps/mobile_flutter/test/ui/group_avatar_mosaic_test.dart`, `chat_forward_picker_page_test.dart`.

- [ ] **Step 1: Write the safe-area RED tests.** Wrap a two-member `GroupAvatarMosaic(size: 44)` in `MediaQuery(data: const MediaQueryData(padding: EdgeInsets.only(top: 32)), child: ...)`. The first grid cell's top must equal the mosaic top plus its existing 4.5% component gap, regardless of `MediaQuery.padding.top`. Add a forwarding-sheet test with one group mosaic and one single avatar and assert their **outer** 44dp squares have equal top and height under the same nonzero top padding.

```dart
final mosaic = tester.getRect(find.byType(GroupAvatarMosaic));
final first = tester.getRect(find.byKey(const Key('group-avatar-member-0')));
expect(first.top, closeTo(mosaic.top + 44 * .045, .5));
expect(mosaic.size, const Size(44, 44));
```

- [ ] **Step 2: Verify RED.** Run `& 'C:/src/flutter/bin/flutter.bat' test --no-pub test/ui/group_avatar_mosaic_test.dart test/ui/chat_forward_picker_page_test.dart`. Expected: the grid inherits 32dp top padding inside a 44dp slot and the first cell is displaced.

- [ ] **Step 3: Fix the shared grid and slot sizing.** In `GroupAvatarMosaic`, set `padding: EdgeInsets.zero` and `primary: false` on the internal `GridView.count`; keep its existing gap/grid algorithm. Keep `ChatForwardCandidate.avatar` and the RoomPage producer unchanged. In `chat_forward_picker_page.dart`, use a private `_ForwardAvatarSlot` with a tight square of 52, 42, or 44dp respectively for recent, row, and confirmation; a `FittedBox(fit: BoxFit.contain)` scales the existing 52dp candidate avatar inside the smaller two slots. This avoids the inner 52dp image/fallback text being clipped by a 42/44dp `SizedBox`. Do not offset avatars with `Transform.translate` or change the shared top safe area.

```dart
GridView.count(
  padding: EdgeInsets.zero,
  primary: false,
  crossAxisCount: gridDimension,
  physics: const NeverScrollableScrollPhysics(),
  mainAxisSpacing: gap,
  crossAxisSpacing: gap,
  childAspectRatio: 1,
  children: [
    for (final avatar in visible)
      Builder(builder: (context) {
        final memberIndex = index++;
        return ClipRRect(
          key: Key('group-avatar-member-$memberIndex'),
          borderRadius: BorderRadius.circular(size * .1),
          child: FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: avatar,
          ),
        );
      }),
  ],
)
```

The picker helper's entire layout is:

```dart
Widget _forwardAvatarSlot(ChatForwardCandidate candidate, double size) =>
    SizedBox.square(
      dimension: size,
      child: FittedBox(fit: BoxFit.contain, child: candidate.avatar),
    );
```

- [ ] **Step 4: Verify GREEN and commit.** Re-run both tests plus `test/features/matrix/matrix_room_media_ui_test.dart` and `test/features/matrix/matrix_conversation_avatar_test.dart`; analyze changed files. Expected: avatars remain square and aligned for zero and nonzero safe-area padding, direct and group forwarding remain functional. Commit this task separately.

## Task 4: Give the transfer picker joined-member search and avatars

**Files:** Modify `apps/mobile_flutter/lib/features/matrix/group_chat_info_page.dart:703-930`; test `apps/mobile_flutter/test/features/matrix/group_chat_info_test.dart`. Reuse `_memberAvatar`, `sortAndFilterMemberEntries`, `ProfileRepository`, and the passed `AvatarMediaCapability`.

- [ ] **Step 1: Write RED picker tests.** From an owner `GroupManagementPage`, open `群主管理权转让`; assert `group-role-search` is present, each eligible member has a 40dp avatar, and selecting a member then filtering to another name does not clear `selected`. Filter by nickname, full/initial pinyin and cached `ContactSummary.username` (畅聊号); an invited member and the current owner must not be offered. Assert `完成` remains enabled only for one eligible selected member and a pending business transfer disables submission.

```dart
await tester.tap(find.text('成员0'));
await tester.enterText(find.byKey(const Key('group-role-search')), 'member1');
await tester.pump();
expect(find.text('成员1'), findsOneWidget);
expect(find.text('成员0'), findsNothing);
await tester.enterText(find.byKey(const Key('group-role-search')), '');
await tester.pump();
expect(find.byIcon(CupertinoIcons.check_mark_circled_solid), findsOneWidget);
```

- [ ] **Step 2: Verify RED.** Run `& 'C:/src/flutter/bin/flutter.bat' test --no-pub test/features/matrix/group_chat_info_test.dart`. Expected: search key and picker avatars are absent; member selection is presently text-only.

- [ ] **Step 3: Implement within the existing picker.** Pass `avatarMedia` from `GroupChatInfoPage` to `GroupManagementPage` and `_GroupRolePicker`. Add local `String query = ''`; construct `MemberDirectoryEntry` from joined non-owner members, using cached remark/nickname/username plus Matrix display-name fallback. Filter via `sortAndFilterMemberEntries(entries, query)`, but keep `selected` keyed by Matrix ID outside the filtered projection. Place a `CupertinoSearchTextField(key: Key('group-role-search'))` above the list. Render each row with `_memberAvatar(..., media: widget.avatarMedia, size: WeChatDimensions.contactAvatar)` and `leadingSize: WeChatDimensions.contactAvatar`; preserve existing trailing selection icon, original permission/cooldown checks and confirmation dialog.

```dart
final contact = widget.identityCache?.contactsByMatrixId[member.matrixUserId];
MemberDirectoryEntry(
  userId: member.matrixUserId,
  remark: contact?.remark,
  nickname: contact?.nickname ?? member.displayName,
  username: contact?.username ?? localPart(member.matrixUserId),
)
```

- [ ] **Step 4: Verify GREEN and commit.** Re-run `group_chat_info_test.dart`, `group_management_permissions_test.dart`, and `test/features/contacts/member_directory_service_test.dart`; analyze the modified page and tests. Expected: avatar/search/selection tests pass and owner-only access remains enforced. Commit this picker task before changing its completion flow.

## Task 5: On authoritative completion, show one toast on group info

**Files:** Modify `apps/mobile_flutter/lib/features/matrix/group_chat_info_page.dart`; test `apps/mobile_flutter/test/features/matrix/group_chat_info_test.dart`. Do not alter `GroupChatInfoController.transferOwnership` or the service contract; only `ownershipTransfer['stage'] == 'COMPLETED'` counts as success.

- [ ] **Step 1: Write RED nested-navigation tests.** Mount `GroupChatInfoPage` with `_OwnerGroupInfoGateway`; the `submitOwnershipTransfer` fake changes `gateway.snapshot.ownerId` to the selected target and returns `{'transfer_id':'intent-1','stage':'COMPLETED'}` so the later `load()` has an authoritative new owner. Enter group management → transfer picker → select → confirm. Assert the picker and management pages are popped, group info remains, one `WeChatToast` reads `群主转让已完成`, `group-transfer-status` and `刷新状态` are absent, and the group-info controller has reloaded the authoritative snapshot. In a second case submit `NEEDS_REVIEW`, verify the picker stays with its status/refresh action, the owner stays unchanged, and there is no success toast. In a third case make refresh advance that **same pending intent** to `COMPLETED` and assert navigation/toast occur exactly once; reopening management must not replay the toast.

- [ ] **Step 2: Verify RED.** Run `& 'C:/src/flutter/bin/flutter.bat' test --no-pub test/features/matrix/group_chat_info_test.dart`. Expected: the current picker stays open, displays `群主转让已完成 / 刷新状态`, and no toast or group-info navigation occurs.

- [ ] **Step 3: Propagate a typed route result upward.** `_GroupRolePickerState` uses a guarded `_completeOnce()` that calls `Navigator.pop(context, true)` only after reading `COMPLETED` from the controller. Call it after `_save()` and after an explicit pending-status refresh; do not trigger it from the initial read of an old completed intent. Keep the status card only for non-`COMPLETED` intents. `GroupManagementPage._pick()` awaits the picker result, then pops management with `true` only for completion. Its page-level message must exclude the stale completed success text while preserving `NEEDS_REVIEW` and failure copy.

```dart
bool _completionHandled = false;
void _completeOnce() {
  if (_completionHandled || !mounted ||
      widget.controller.ownershipTransfer?['stage'] != 'COMPLETED') return;
  _completionHandled = true;
  Navigator.of(context).pop(true);
}
```

- [ ] **Step 4: Finish on the still-mounted group-info page.** Make the `群管理` tile await `Navigator.push<bool>`. On `true`, initiate `controller.load()` to refresh the authoritative group info, then call `showWeChatToast(context, '群主转让已完成', semanticType: WeChatToastSemanticType.success)` from that page's context; do not show the toast in a route being popped. The controller continues to decide owner and cool-down truth. Import the existing `ui/components/wechat_toast.dart`; no new toast widget is needed.

- [ ] **Step 5: Verify GREEN and commit.** Re-run the nested-navigation tests, `group_management_permissions_test.dart`, and `core/group_transfer_client_test.dart`; analyze changed files. Expected: one completion toast, group-info destination, pending and error paths intact, no duplicate Matrix ownership write. Commit this navigation task separately.

## Task 6: Keep the HTML demo and shared registry in step

**Files:** Modify `frontend/src/screens/messaging.js`; create `frontend/tests/android-search-forward-transfer-demo.test.mjs`. **Root serial integration only:** modify `frontend/src/styles/primitives.css`, `frontend/src/catalog/screens.js` and `packages/ui-contracts/changliao-component-registry.json` after the wallet and messaging screen work lands. Do not edit these root-owned files in parallel with other UI modules.

- [ ] **Step 1: Write failing demo assertions.** Register and render reviewable IDs for chat-history search results/empty, global search group/direct/history avatars, forward confirmation, transfer member search/selected, pending review and completed-return. In the new Node test, assert the registered IDs resolve and their rendered DOM has a 40px avatar slot for search/transfer, 44px forward confirmation avatar, a transfer search input, and no old undecrypted warning or completed status card. Use the existing `group-moments-wallet-demo.test.mjs` fake DOM approach or the browser harness; test selection survives filtering and completed state navigates back to group-info in the demo interaction.

```js
for (const id of [
  'chat-search-history-results',
  'chat-search-global-results',
  'chat-group-management-transfer-members',
  'chat-group-management-transfer-pending',
  'chat-group-management-transfer-completed',
]) assert.equal(getScreen(id).id, id);
assert.doesNotMatch(messagingSource, /部分本地消息尚未解密，无法完整检索/u);
```

- [ ] **Step 2: Verify RED.** From `frontend`, run `node --test tests/android-search-forward-transfer-demo.test.mjs`. Expected: the new states, avatar DOM and role search do not exist in the current demo.

- [ ] **Step 3: Implement demo presentation with existing tokens.** In `messaging.js`, add focused `searchResults(definition)` and `transferMemberPicker(definition)` render branches plus a small `demoAvatar(name, size)` helper using `component('app-avatar', {name, size})`. Make forward target rows and the `发送给` confirmation contain avatars beside the label. Root then updates shared `primitives.css` serially: use existing `--size-avatar-message` (40px) for search/transfer, a `44px` confirmation slot, existing spacing/color/radius variables, and no absolute top compensation. The completed transfer state renders group-info with a transient success notice; pending review stays on the picker with a refresh action. Root adds only the five named `register(...)` states in `screens.js` once the renderer is ready.

```js
const avatar = component('app-avatar', { name: target.title, size: 'message' });
const option = button('c-forward-picker__target', '', 'forward:target');
option.append(avatar, element('span', 'c-forward-picker__name', target.title));
```

- [ ] **Step 4: Update the registry and verify GREEN.** Root appends a dated `feedbackContracts` entry mapping each screen state to its Flutter page, 40/44dp avatar slot, search/status transitions, and `WeChatToast` completion. Run `node --test tests/android-search-forward-transfer-demo.test.mjs tests/group-moments-wallet-demo.test.mjs`, then `npm run verify` from `frontend`; run `pwsh -NoProfile -File scripts/verify.ps1` only after checking environment and using the mobile workflow's change-impact/evidence-reuse rules. Open the demo page in a browser and record the exact URL/screen IDs plus light/dark screenshot or layout observations in the task evidence. Expected: node and demo verification pass, no overflow or icon clipping at 393×852, Flutter and HTML labels/spacing agree. Commit demo/module files, then root's catalog/registry change separately.

## Task 7: Integrated review, Debug handoff and truthful limits

**Files:** Update `docs/workflow/tasks/2026-09-29-android-2191-followup.md`; record non-Git logs and screenshots under `docs/verification/artifacts/2026-09-29/android-2191-followup/`. Root owns version/build integration and Android packaging; do not let a UI subagent install an intermediate Flutter APK.

- [ ] **Step 1: Run a specification-compliance review before quality/security review.** Check every accepted design case: warning absent with coverage flag retained; group/private/history avatars and 40dp rows; nonzero safe-area mosaic; search persistence; `COMPLETED` one toast and group-info route; `NEEDS_REVIEW` unchanged; HTML/registry parity. Fix any failure with a focused RED/GREEN cycle.
- [ ] **Step 2: Run relevant Flutter widget tests and analyzer, then applicable repository gates.** Use `& 'C:/src/flutter/bin/flutter.bat' test --no-pub` on the five focused test files above; analyze their changed library/test paths; preflight and run `pwsh -NoProfile -File scripts/verify.ps1` where applicable. Reuse unchanged equivalent evidence only under `mobile-delivery-workflow.md`, never label an exit 1 as a full pass.
- [ ] **Step 3: Integrate once and build a higher Debug build.** Root checks current installed version/signature, freezes source hash, bumps beyond 2191 without reusing another task's build number, follows `docs/runbooks/android-apk-rebuild.md` (source → Apktool DEX/resource/manifest rebuild → alignment → stable Debug signer → independent verify), and installs with `adb -s emulator-5556 install -r --no-streaming <final.apk>` without uninstalling or clearing data. Verify package/build, certificate digest, first-install time retained, and launch. Test the actual navigation/avatars on simulator; only a physical device can establish Redmi K80 rendering/performance behavior.
- [ ] **Step 4: Record evidence and handoff.** Put commands, real exit codes, source/artifact SHA, HTML demo URL, simulator identity, before/after app version, and any unresolved device-only item in the task record. Report the final APK path and what remains unverified; no server publication or iOS claim follows from this UI plan.

## Plan self-review

- Specification coverage: search copy/coverage (Task 1), search avatar source and 40dp slot (Task 2), forward safe-area and sizing (Task 3), role picker search/avatar (Task 4), authoritative completion/pending distinction (Task 5), HTML/registry parity (Task 6), simulator delivery and gate (Task 7).
- Protected boundaries: Matrix message plaintext never leaves device; no backend, wallet, authentication, E2EE or migration code in scope.
- Shared files: `screens.js`/registry are root-serial, `group_chat_info_page.dart` Tasks 4→5 are sequential, and `room_page.dart` must not overlap the media owner.
