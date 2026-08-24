# 拍一拍、聊天历史保留与通讯录标签 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将“拍一拍”改为无气泡居中系统文本；同一账号退出后重新登录保留本机可解密历史；完成通讯录标签管理、标签好友、导入和批量移出流程。

**Architecture:** Matrix 是唯一的聊天密文与密钥域，业务 API 只提供认证、联系人与标签权威数据。正常退出仅暂停并重新打开相同 SQLCipher Matrix 本地库；仅在身份不一致、Matrix 会话权威失效或用户明确清除本机聊天数据时销毁本地库。标签所有写入经 Friendship 应用服务完成，并在同一事务内更新联系人标签投影、审计与 Outbox。

**Tech Stack:** Flutter/Dart、Cupertino、Matrix Dart SDK、SQLCipher、FastAPI、SQLAlchemy、OpenAPI、Figma export ledger、Python/Node/PowerShell。

---

## 已定位的历史消息根因

1. **不是未同步到服务器。** 会话仍能显示，说明 Matrix 已同步到历史事件；`The sender has not sent us the session...` 是新客户端无法解密历史 `m.room.encrypted` 事件时 Matrix SDK 的 Megolm 会话缺失提示。
2. **直接原因是本地库被清除。** `SessionBootstrapController.logout()` → `MatrixSdkE2eeClient.logout()` → `MatrixClientFactory.reset()`；`reset()` 删除 `liuhetong_matrix.sqlite` 并执行 `clearMatrixDatabaseKey()`。SQLCipher 内的同步缓存、Olm identity/session、Megolm inbound session 与备份元数据随之消失。
3. **修复策略。** 同一账号正常退出仅关闭内存客户端并重新打开相同 SQLCipher 数据库/密钥；重登时复用同一 Matrix 设备。换账号、`M_UNKNOWN_TOKEN`、`M_FORBIDDEN` 和用户显式清除设备聊天数据才执行销毁。真正的新设备只能经已验证设备或恢复密钥恢复；恢复密钥绝不传给业务 API。
4. **已确认标签层级。** 通讯录“标签”进入 **通讯录标签**，无右上角更多图标，底部为“新建 / 编辑”；具体标签进入标签好友页，该页保留右上角更多、搜索、字母排序及“添加 / 移出”。

## File map

- Create `apps/mobile_flutter/lib/ui/chat/wechat_nudge_notice.dart`：透明、居中的拍一拍组件。
- Modify `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`：系统拍一拍事件不再进入 `WeChatMessageBubble`。
- Modify `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart`、`matrix_client_factory.dart`、`login_controller.dart`、`session_bootstrap_controller.dart`、`main.dart`：保留/销毁 Matrix 本地库的明确生命周期。
- Modify `apps/mobile_flutter/lib/core/business_api_client.dart`、`session_store.dart`：身份感知的 Matrix grant 与存储保留。
- Create `apps/mobile_flutter/lib/features/contacts/contact_tag_models.dart`、`contact_tag_pages.dart`：标签摘要、纯排序/成员操作函数与页面。
- Modify `contacts_page.dart`、`app_home.dart`、`contact_models.dart`：入口、群聊好友导入与 typed gateway。
- Modify `services/business-api/app/api/{identity,friendship}.py`、`app/modules/{identity/matrix_login,friendship/service}.py`、`packages/api-contracts/openapi/liuhetong-v1.yaml`：grant 中的权威 MXID、标签统计/批量删除与投影同步。
- Modify `design-demo/artifacts/figma-state.json`、`packages/ui-contracts/changliao-component-registry.json`：Figma ledger 与三方契约。
- Tests: `apps/mobile_flutter/test/{ui,wechat_nudge_notice_test.dart,features/matrix,features/auth,core,features/contacts/contact_flow_test.dart}`、`tests/business_api/{identity/friendship}/`。
- Create `docs/verification/2026-08-23-nudge-history-tags-ui-review.md`：红绿、Figma、真机/模拟器及全仓验证证据。

## Task 1: Figma and UI-contract registration

**Files:** `design-demo/artifacts/figma-state.json`, `packages/ui-contracts/changliao-component-registry.json`, `tests/mobile/test_ui_component_registry.py`

- [ ] **Step 1: Inspect and update Figma first.** Load the Figma-use and Figma-generate-design skills, then inspect existing pages `18:7` (消息/聊天) and `19:3` (通讯录/好友). Reuse variables and components. Create/update child frames for `app-nudge-notice`、`app-contact-tag-management`、`app-contact-tag-members`、`app-contact-tag-friend-picker`，并记录 Figma 返回的真实 node ID。
- [ ] **Step 2: Write a failing registry test.**
  ```python
  required = {
      'nudge-notice': 'WeChatNudgeNotice',
      'contact-tag-management': 'ContactTagsPage',
      'contact-tag-members': 'ContactTagMembersPage',
      'contact-tag-friend-picker': 'ContactTagFriendPickerPage',
  }
  actual = {item['id']: item['flutter']['name'] for item in registry['components']}
  assert actual.items() >= required.items()
  ```
- [ ] **Step 3: Verify RED.**
  ```powershell
  py -3.12 -m pytest tests/mobile/test_ui_component_registry.py -q
  ```
  Expected: FAIL because the new components/keys do not exist.
- [ ] **Step 4: Update ledger and registry.** Add actual child keys, source files, HTML tags, props, variants, and `default / pressed / disabled / loading / error / empty / destructive` states. Use existing semantic tokens; nudge maps transparent surface/text-secondary/caption/spacing only.
- [ ] **Step 5: Verify GREEN.**
  ```powershell
  py -3.12 -m pytest tests/mobile/test_ui_component_registry.py -q
  python scripts/verify_ui_contract.py
  ```
- [ ] **Step 6: Commit.**
  ```powershell
  git add design-demo/artifacts/figma-state.json packages/ui-contracts/changliao-component-registry.json tests/mobile/test_ui_component_registry.py
  git commit -m "docs(ui): register nudge and contact tag surfaces"
  ```

## Task 2: Plain centered 拍一拍 notice

**Files:** Create `apps/mobile_flutter/lib/ui/chat/wechat_nudge_notice.dart`; Modify `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`; Test `apps/mobile_flutter/test/ui/wechat_nudge_notice_test.dart`, `apps/mobile_flutter/test/features/matrix/room_page_presentation_test.dart`

- [ ] **Step 1: Write failing widget tests.**
  ```dart
  testWidgets('nudge notice centers text without a message bubble', (tester) async {
    await tester.pumpWidget(const CupertinoApp(home: WeChatNudgeNotice(text: '小明拍了拍我')));
    expect(find.byKey(const Key('nudge-notice')), findsOneWidget);
    expect(find.byKey(const Key('nudge-notice-bubble')), findsNothing);
    expect(tester.widget<Align>(find.byKey(const Key('nudge-notice-align'))).alignment, Alignment.center);
  });
  ```
  Add a Room test asserting `RoomMessageKind.system` uses `WeChatNudgeNotice`, never `WeChatMessageBubble` or `message-avatar-slot`.
- [ ] **Step 2: Verify RED.**
  ```powershell
  Set-Location apps/mobile_flutter
  C:\src\flutter\bin\flutter.bat test test/ui/wechat_nudge_notice_test.dart test/features/matrix/room_page_presentation_test.dart
  ```
  Expected: compile failure because notice and render branch are absent.
- [ ] **Step 3: Implement only the transparent surface.**
  ```dart
  final class WeChatNudgeNotice extends StatelessWidget {
    const WeChatNudgeNotice({super.key, required this.text});
    final String text;
    @override
    Widget build(BuildContext context) => Align(
      key: const Key('nudge-notice-align'), alignment: Alignment.center,
      child: Padding(key: const Key('nudge-notice'),
        padding: const EdgeInsets.symmetric(vertical: WeChatSpacing.sm),
        child: Text(text, style: const TextStyle(color: WeChatColors.textSecondary, fontSize: WeChatTypography.caption))),
    );
  }
  ```
  In `RoomPage`, render timestamps unchanged, then branch `RoomMessageKind.system` to this widget before the bubble. Retain current E2EE event type/payload/send gesture/order.
- [ ] **Step 4: Verify GREEN.**
  ```powershell
  C:\src\flutter\bin\dart.bat format --output=none --set-exit-if-changed lib/ui/chat/wechat_nudge_notice.dart lib/features/matrix/matrix_home_page.dart test/ui/wechat_nudge_notice_test.dart test/features/matrix/room_page_presentation_test.dart
  C:\src\flutter\bin\flutter.bat test test/ui/wechat_nudge_notice_test.dart test/features/matrix/room_page_presentation_test.dart
  ```
- [ ] **Step 5: Commit.**
  ```powershell
  git add apps/mobile_flutter/lib/ui/chat/wechat_nudge_notice.dart apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart apps/mobile_flutter/test/ui/wechat_nudge_notice_test.dart apps/mobile_flutter/test/features/matrix/room_page_presentation_test.dart
  git commit -m "feat(chat): render nudges as centered plain notices"
  ```

## Task 3: Preserve local encrypted Matrix history

**Files:** Modify `matrix_e2ee_client.dart`, `matrix_client_factory.dart`, `login_controller.dart`, `session_bootstrap_controller.dart`, `main.dart`, `business_api_client.dart`, `session_store.dart`; Test `matrix_client_factory_test.dart`, `login_controller_test.dart`, `session_bootstrap_controller_test.dart`, `session_store_test.dart`

- [ ] **Step 1: Write failing lifecycle tests.**
  ```dart
  test('suspend reopens encrypted Matrix storage without deleting database or key', () async {
    await matrix.suspend();
    expect(events, ['dispose:old', 'open:liuhetong_mobile']);
    expect(await secureStore.matrixDatabaseKey(), oldKey);
  });
  test('same Matrix identity reuses persisted device after business login', () async {
    await service.login('alice', 'password');
    expect(matrix.loginTokens, isEmpty);
    expect(matrix.syncCalls, 1);
  });
  test('different Matrix identity destroys old local store before token login', () async {
    await service.login('bob', 'password');
    expect(matrix.resetCalls, 1);
  });
  ```
  Assert `SessionBootstrapController.logout()` calls business logout + `suspend`, never destroy; retain existing test that `clearBusinessSession()` leaves Matrix DB key intact.
- [ ] **Step 2: Verify RED.**
  ```powershell
  Set-Location apps/mobile_flutter
  C:\src\flutter\bin\flutter.bat test test/features/matrix/matrix_client_factory_test.dart test/features/auth/login_controller_test.dart test/core/session_bootstrap_controller_test.dart test/core/session_store_test.dart
  ```
- [ ] **Step 3: Separate non-destructive and destructive lifecycle methods.**
  ```dart
  abstract interface class MatrixSessionGateway {
    bool get isLoggedIn;
    String? get userId;
    Future<void> sync();
    Future<void> suspend();         // dispose/reopen; keep SQLCipher DB/key
    Future<void> resetLocalStore(); // dispose/delete DB/clear DB key/reopen
  }
  ```
  Add `MatrixClientFactory.reopen` (dispose + create only); keep current `reset` for deletion. Implement `MatrixSdkE2eeClient.suspend` via reopen and `resetLocalStore` via reset. Do not invoke SDK `logout()` during ordinary business logout.
- [ ] **Step 4: Make login identity-aware.** Extend `MatrixLoginGrant` with required `matrixUserId`. On login, issue grant; if existing Matrix user equals grant MXID, only sync; if another MXID, `resetLocalStore()` then token login; if not logged in, token login. Require `matrix.userId == grant.matrixUserId`, then persist with `bindMatrixUserId`. In bootstrap, invalid token and `M_UNKNOWN_TOKEN`/`M_FORBIDDEN` call `resetLocalStore`; ordinary logout calls `suspend`. Pass both factory callbacks in `main.dart`.
- [ ] **Step 5: Verify GREEN.**
  ```powershell
  C:\src\flutter\bin\dart.bat format --output=none --set-exit-if-changed lib/features/matrix/matrix_e2ee_client.dart lib/features/matrix/matrix_client_factory.dart lib/features/auth/login_controller.dart lib/core/session_bootstrap_controller.dart lib/main.dart lib/core/business_api_client.dart lib/core/session_store.dart test/features/matrix/matrix_client_factory_test.dart test/features/auth/login_controller_test.dart test/core/session_bootstrap_controller_test.dart test/core/session_store_test.dart
  C:\src\flutter\bin\flutter.bat test test/features/matrix/matrix_client_factory_test.dart test/features/auth/login_controller_test.dart test/core/session_bootstrap_controller_test.dart test/core/session_store_test.dart
  ```
- [ ] **Step 6: Commit.**
  ```powershell
  git add apps/mobile_flutter/lib/features/matrix apps/mobile_flutter/lib/features/auth/login_controller.dart apps/mobile_flutter/lib/core/session_bootstrap_controller.dart apps/mobile_flutter/lib/core/business_api_client.dart apps/mobile_flutter/lib/core/session_store.dart apps/mobile_flutter/lib/main.dart apps/mobile_flutter/test/features/matrix/matrix_client_factory_test.dart apps/mobile_flutter/test/features/auth/login_controller_test.dart apps/mobile_flutter/test/core/session_bootstrap_controller_test.dart apps/mobile_flutter/test/core/session_store_test.dart
  git commit -m "fix(matrix): retain encrypted history across same-account logout"
  ```

## Task 4: Expose authoritative MXID in existing Matrix login grant

**Files:** Modify `services/business-api/app/api/identity.py`, `app/modules/identity/matrix_login.py`, `packages/api-contracts/openapi/liuhetong-v1.yaml`; Test `tests/business_api/identity/test_matrix_login.py`

- [ ] **Step 1: Write failing API test.**
  ```python
  response = await client.post('/api/v1/auth/matrix-login-token', headers=bearer(settings, 'u1'))
  assert response.status_code == 200
  assert response.json()['matrix_user_id'] == '@alice:matrix.example.test'
  assert set(response.json()) == {'login_token', 'homeserver', 'expires_in', 'matrix_user_id'}
  ```
  Add missing-MXID test that returns the existing domain error rather than guessing an MXID.
- [ ] **Step 2: Verify RED.** `py -3.12 -m pytest tests/business_api/identity/test_matrix_login.py -q` — expected missing `matrix_user_id`.
- [ ] **Step 3: Implement additive response.** Return existing `User.matrix_user_id`, require it nonempty, and add required `matrix_user_id` to OpenAPI response schema. No existing grant field changes.
- [ ] **Step 4: Verify GREEN.**
  ```powershell
  py -3.12 -m pytest tests/business_api/identity/test_matrix_login.py -q
  python scripts/verify_openapi.py
  ```
- [ ] **Step 5: Commit.**
  ```powershell
  git add services/business-api/app/api/identity.py services/business-api/app/modules/identity/matrix_login.py packages/api-contracts/openapi/liuhetong-v1.yaml tests/business_api/identity/test_matrix_login.py
  git commit -m "feat(auth): return Matrix identity in login grant"
  ```

## Task 5: Make tag rename/delete projections atomic

**Files:** Modify `services/business-api/app/api/friendship.py`, `app/modules/friendship/service.py`, `packages/api-contracts/openapi/liuhetong-v1.yaml`; Test `tests/business_api/friendship/test_friendship_api.py`

- [ ] **Step 1: Write failing API tests.** Assert rename changes `GET /friends` tag values; `DELETE /contact-tags` with `{"tag_ids":[tagA,tagB]}` removes both tags and all owner `ContactProfile.tags` values; mixed-owner batch fails `404 CONTACT_TAG_NOT_FOUND` without deletion; `GET /contact-tags` returns `{id,name,friend_count}`.
- [ ] **Step 2: Verify RED.** `py -3.12 -m pytest tests/business_api/friendship/test_friendship_api.py -q` — expected missing batch route/count and stale projections.
- [ ] **Step 3: Implement one transaction.** Add `TagDeleteBatchBody(tag_ids: list[str])` with 1–30 items. `delete_tags(actor, tag_ids, key)` validates all owner rows first, removes every matching exact comma-separated tag from owner profiles, emits audit/Outbox with `CONTACT_TAG_DELETE`, then deletes rows. `rename_tag` replaces exact old name in all owner profiles in the same transaction. `tags(actor)` calculates `friend_count`; single delete delegates to batch delete.
- [ ] **Step 4: Update OpenAPI.** Document additive bulk DELETE, typed tag summary, `Idempotency-Key`, 404 `CONTACT_TAG_NOT_FOUND`, and examples.
- [ ] **Step 5: Verify GREEN.**
  ```powershell
  py -3.12 -m pytest tests/business_api/friendship/test_friendship_api.py -q
  python scripts/verify_openapi.py
  ```
- [ ] **Step 6: Commit.**
  ```powershell
  git add services/business-api/app/api/friendship.py services/business-api/app/modules/friendship/service.py packages/api-contracts/openapi/liuhetong-v1.yaml tests/business_api/friendship/test_friendship_api.py
  git commit -m "feat(contacts): manage tag projections and batch deletion"
  ```

## Task 6: 通讯录标签 management page

**Files:** Create `contact_tag_models.dart`, `contact_tag_pages.dart`; Modify `contact_models.dart`, `business_api_client.dart`, `contacts_page.dart`; Test `contact_flow_test.dart`

- [ ] **Step 1: Write failing tests.**
  ```dart
  testWidgets('contact tag management has bottom new edit bar and no more icon', (tester) async {
    await tester.pumpWidget(CupertinoApp(home: ContactTagsPage(api: gateway)));
    await tester.pumpAndSettle();
    expect(find.text('通讯录标签'), findsOneWidget);
    expect(find.byKey(const Key('contact-tags-new')), findsOneWidget);
    expect(find.byKey(const Key('contact-tags-edit')), findsOneWidget);
    expect(find.byKey(const Key('contact-tags-more')), findsNothing);
  });
  ```
  Test “新建” opens **设置标签名称**, saves/reloads authoritative data, and edit-mode two-selection confirms/destructively batch-deletes. Unit test `ContactTagSummary.fromJson` and case-insensitive `sortContactTags`.
- [ ] **Step 2: Verify RED.**
  ```powershell
  Set-Location apps/mobile_flutter
  C:\src\flutter\bin\flutter.bat test test/features/contacts/contact_flow_test.dart
  ```
- [ ] **Step 3: Add typed gateway.** Create `ContactTagSummary(id,name,friendCount)`, `listContactTags()` and `deleteContactTags(List<String>)`. `BusinessApiClient` decodes typed data and invokes one bulk DELETE with an idempotency key; retain `renameContactTag` for the member-page menu.
- [ ] **Step 4: Implement confirmed layout.** `ContactTagsPage` uses `WeChatPageScaffold.navigation`, middle **通讯录标签**, no trailing button, typed loading/error/empty states and tag rows with “N 位朋友”. Bottom keys: `contact-tags-new`, `contact-tags-edit`. “新建” opens `CupertinoAlertDialog` titled **设置标签名称**, preserves draft and visibly errors on failed save. “编辑” enables multi-select; destructive delete is disabled without selections and must show a second red confirmation before one gateway call.
- [ ] **Step 5: Verify GREEN and commit.**
  ```powershell
  C:\src\flutter\bin\dart.bat format --output=none --set-exit-if-changed lib/features/contacts/contact_tag_models.dart lib/features/contacts/contact_tag_pages.dart lib/features/contacts/contact_models.dart lib/core/business_api_client.dart lib/features/contacts/contacts_page.dart test/features/contacts/contact_flow_test.dart
  C:\src\flutter\bin\flutter.bat test test/features/contacts/contact_flow_test.dart
  git add apps/mobile_flutter/lib/features/contacts apps/mobile_flutter/lib/core/business_api_client.dart apps/mobile_flutter/test/features/contacts/contact_flow_test.dart
  git commit -m "feat(contacts): add contact tag management page"
  ```

## Task 7: Tag friend list, imports and batch removal

**Files:** Modify `contact_tag_models.dart`, `contact_tag_pages.dart`, `contacts_page.dart`, `app_home.dart`; Test `contact_flow_test.dart`

- [ ] **Step 1: Write failing tests.** Test `ContactTagMembersPage` exposes `tag-members-search`, alphabetical member order, `tag-members-more`, “添加/移出”; test picker contains **导入群聊中的朋友** and **导入标签中的朋友**; test two selected members are removed; test overflow rename and red second delete confirmation.
- [ ] **Step 2: Verify RED.** `C:\src\flutter\bin\flutter.bat test test/features/contacts/contact_flow_test.dart` — expected absent pages/actions.
- [ ] **Step 3: Implement pure membership helpers.**
  ```dart
  List<ContactSummary> contactsForTag(Iterable<ContactSummary> all, String tag) =>
      all.where((c) => c.tags.contains(tag)).toList()..sort((a,b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
  List<String> mergeTag(List<String> tags, String tag) => ({...tags, tag}.toList()..sort());
  List<String> removeTag(List<String> tags, String tag) => tags.where((value) => value != tag).toList();
  ```
- [ ] **Step 4: Implement member and picker pages.** Member page has search, alphabetical list, more menu (**更改标签名称 / 删除标签**) and bottom **添加 / 移出**. Delete menu action uses `isDestructiveAction: true`, deletes one tag then pops/reloads parent. Add picker lists non-members with search and two import entries. Group import intersects joined Matrix room members with already-authoritative Business contacts; it never sends Matrix member data to the Business API. Source-tag import uses typed tags. All add/remove writes call `updateContactDetails`, disable while active, retain selections/errors on failure, and reload authoritative contacts on success.
- [ ] **Step 5: Verify GREEN and commit.**
  ```powershell
  C:\src\flutter\bin\dart.bat format --output=none --set-exit-if-changed lib/features/contacts/contact_tag_models.dart lib/features/contacts/contact_tag_pages.dart lib/features/contacts/contacts_page.dart lib/app_home.dart test/features/contacts/contact_flow_test.dart
  C:\src\flutter\bin\flutter.bat test test/features/contacts/contact_flow_test.dart
  git add apps/mobile_flutter/lib/features/contacts apps/mobile_flutter/lib/app_home.dart apps/mobile_flutter/test/features/contacts/contact_flow_test.dart
  git commit -m "feat(contacts): manage friends from contact tags"
  ```

## Task 8: Full workflow verification and evidence

**Files:** Create `docs/verification/2026-08-23-nudge-history-tags-ui-review.md`

- [ ] **Step 1: Run focused gates.**
  ```powershell
  Set-Location apps/mobile_flutter
  C:\src\flutter\bin\flutter.bat test test/ui/wechat_nudge_notice_test.dart test/features/matrix/room_page_presentation_test.dart test/features/matrix/matrix_client_factory_test.dart test/features/auth/login_controller_test.dart test/core/session_bootstrap_controller_test.dart test/features/contacts/contact_flow_test.dart
  Set-Location ../..
  py -3.12 -m pytest tests/business_api/identity/test_matrix_login.py tests/business_api/friendship/test_friendship_api.py -q
  ```
- [ ] **Step 2: Run all required gates.**
  ```powershell
  Set-Location apps/mobile_flutter; C:\src\flutter\bin\flutter.bat analyze; C:\src\flutter\bin\flutter.bat test
  Set-Location ../..; python scripts/verify_ui_contract.py
  Set-Location design-demo; npm test
  Set-Location ..; pwsh.exe -NoProfile -File scripts/verify.ps1
  ```
  Expected: all exit `0`.
- [ ] **Step 3: Run controlled functional regression.** On test device A, verify an already-readable encrypted message; logout/relogin same account; sync and verify it remains readable without the English session error. Log in to account B and prove identity mismatch uses destructive reset before B appears. On a test copy with cleared local Matrix storage, prove recovery requires verified device/recovery key. Record no secrets, plaintext bodies or recovery keys.
- [ ] **Step 4: Complete Figma review evidence.** Record exact Figma changed-node URLs, ledger/registry paths, red/green outputs and this result: nudge is centered/transparent; 通讯录标签 has no more icon and new/edit bottom actions; destructive actions use danger tokens. Explain the old reset deletion root cause and E2EE boundary.
- [ ] **Step 5: Commit.**
  ```powershell
  git add docs/verification/2026-08-23-nudge-history-tags-ui-review.md design-demo/artifacts/figma-state.json packages/ui-contracts/changliao-component-registry.json
  git commit -m "docs(ui): verify nudge history and contact tag flows"
  git status --short
  ```

## Plan self-review

- Task 2 covers the no-bubble centered nudge.
- Tasks 3–4 cover observed local-key deletion, same-account retention, identity separation and the additive grant contract.
- Tasks 5–7 cover management page, tags page, searches, ordering, more menu, imports, multi-remove and batch tag deletion.
- Tasks 1 and 8 enforce Figma-first registry/ledger/drift/review/verification workflow.
- No Matrix plaintext, recovery key, room key or decrypted media crosses into business APIs; financial domains are untouched.
