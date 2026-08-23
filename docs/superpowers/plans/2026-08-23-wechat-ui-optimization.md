# ChatFlow 微信式 UI 优化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按阶段实现资料/好友设置与聊天信息、搜索与日期选择器、群成员实时同步，并让 Figma 导出账本成为每阶段的视觉验收源。

**Architecture:** 阶段一扩展 ProfileGateway/Profile API 的资料字段，重做联系人设置子页面并通过 ContactsGateway 返回权威状态；聊天信息页只负责导航。阶段二抽出共享微信式 DatePicker、历史搜索分组模型和全局搜索模型。阶段三让群聊天信息订阅成员变更并复用统一排序器。每阶段都先写失败测试，再实现最小改动，最后更新 Figma ledger、注册表和审查记录。

**Tech Stack:** Flutter/Cupertino、FastAPI/Pydantic、Matrix adapters、JSON Figma export ledger、Python/Node/PowerShell verification。

---

## Task 1: 阶段一契约与 Figma 登记

**Files:**
- Modify: `apps/mobile_flutter/lib/features/profile/profile_controller.dart`
- Modify: `services/business-api/app/api/profile.py`
- Modify: `services/business-api/app/modules/identity/profile.py`
- Modify: `apps/mobile_flutter/lib/core/business_api_client.dart`
- Modify: `design-demo/artifacts/figma-state.json`
- Modify: `packages/ui-contracts/changliao-component-registry.json`
- Test: `apps/mobile_flutter/test/features/profile/profile_controller_test.dart`
- Test: `tests/business_api/test_profile_api.py`

- [ ] **Step 1: Write failing tests**
  - Assert `ProfileData.nudgeSuffix` round-trips through gateway JSON.
  - Assert `ProfileController.save` forwards `nudgeSuffix` and preserves the old value plus an error state when the gateway throws.
  - Assert profile API accepts `nudge_suffix`, returns it, and rejects more than 32 characters.
- [ ] **Step 2: Run focused tests and verify RED**
  - Run `C:\srclutterinlutter.bat test test/features/profile/profile_controller_test.dart` from `apps/mobile_flutter`; expected failure: missing `nudgeSuffix` field/argument.
  - Run `py -3.12 -m pytest tests/business_api/test_profile_api.py -q`; expected failure: response has no `nudge_suffix`.
- [ ] **Step 3: Implement the field end-to-end**
  - Add `nudgeSuffix` to `ProfileData`, `ProfileGateway.updateProfile`, client JSON encode/decode, `ProfilePatch`, `ProfileResponse`, and profile service persistence/model using an expand-compatible nullable column or existing profile metadata field.
  - Keep empty input as `null`; enforce Unicode length <= 32 at API and controller boundaries.
- [ ] **Step 4: Run tests GREEN**
  - Repeat both commands; expected all focused tests pass.
- [ ] **Step 5: Update Figma ledger and registry**
  - Add page/frame registrations and component mapping for `ProfileNudgeRow`, `ContactTagPicker`, `DeleteConfirmation`, and `FriendProfileEntry`; include states default/pressed/disabled/error and existing semantic token names only.
  - Run `python scripts/verify_ui_contract.py` and record output in `docs/verification/2026-08-23-phase1-ui-review.md`.
- [ ] **Step 6: Commit**
  - `git add apps/mobile_flutter/lib/features/profile services/business-api/app/api/profile.py services/business-api/app/modules/identity/profile.py apps/mobile_flutter/lib/core/business_api_client.dart design-demo/artifacts/figma-state.json packages/ui-contracts tests docs/verification/2026-08-23-phase1-ui-review.md`
  - `git commit -m "feat(profile): persist nudge suffix and register phase one UI"`

## Task 2: 个人信息页拍一拍入口

**Files:**
- Modify: `apps/mobile_flutter/lib/features/profile/profile_page.dart`
- Test: `apps/mobile_flutter/test/features/profile/profile_controller_test.dart`

- [ ] **Step 1: Write failing widget tests**
  - `ProfileDetailsPage` contains `Key('profile-nudge-row')`, opens an editor, saves text, and shows the saved suffix.
  - `DirectChatInfoPage` test asserts `find.text('设置拍一拍')` is empty.
- [ ] **Step 2: Run tests and verify RED**
  - Run the profile and direct-chat widget test files; expected failure because the row and field do not exist.
- [ ] **Step 3: Implement minimal UI**
  - Add a tappable `CupertinoListTile` in the existing inset-grouped personal info section.
  - Use a dedicated `CupertinoPageRoute` editor with cancel/save; call `ProfileController.save` with unchanged nickname/signature and new nudge suffix.
  - Show `ProfileState.message` inline and preserve draft on errors.
- [ ] **Step 4: Run GREEN and refactor**
  - Run focused tests, then `flutter analyze`.
- [ ] **Step 5: Commit**
  - `git add apps/mobile_flutter/lib/features/profile/profile_page.dart apps/mobile_flutter/test/features/profile/profile_controller_test.dart apps/mobile_flutter/test/features/matrix/direct_chat_info_page_test.dart`
  - `git commit -m "feat(profile): move nudge setting to personal information"`

## Task 3: 好友备注、标签和删除规范

**Files:**
- Modify: `apps/mobile_flutter/lib/features/contacts/contacts_page.dart`
- Modify: `apps/mobile_flutter/lib/features/contacts/contact_models.dart`
- Modify: `apps/mobile_flutter/lib/core/business_api_client.dart`
- Modify: `services/business-api/app/api/friendship.py`
- Modify: `services/business-api/app/modules/friendship/service.py`
- Test: `apps/mobile_flutter/test/features/contacts/contact_flow_test.dart`
- Test: `tests/business_api/test_friendship_api.py`

- [ ] **Step 1: Write failing tests**
  - Tap remark, edit, save; assert profile and list title show new value.
  - Tap tags; assert a multi-select page with selected tags, create, rename, delete, and completion callback.
  - Assert delete action text/button alignment is centered and confirmation uses “取消/删除”.
  - Assert API supports tag rename with idempotency and rejects deleting a tag owned by another user.
- [ ] **Step 2: Run focused tests and verify RED**
  - Run `flutter test test/features/contacts/contact_flow_test.dart`; expected failure because tags currently use comma text input and delete action is not centered.
  - Run `py -3.12 -m pytest tests/business_api/test_friendship_api.py -q`; expected failure for missing PATCH tag route.
- [ ] **Step 3: Implement minimal UI/API**
  - Replace `_editText('设置标签', tags)` with `ContactTagPickerPage` and return `ContactMoreResult.updated` using authoritative `ContactDetails`.
  - Add `PATCH /contact-tags/{tag_id}` and client method; update tag list in place after create/rename/delete.
  - Center destructive rows/actions and show errors using existing WeChat dialog/toast components.
- [ ] **Step 4: Run GREEN**
  - Repeat focused Flutter/API tests; expected pass.
- [ ] **Step 5: Commit**
  - `git add apps/mobile_flutter/lib/features/contacts apps/mobile_flutter/lib/core/business_api_client.dart services/business-api/app/api/friendship.py services/business-api/app/modules/friendship tests`
  - `git commit -m "feat(contacts): add WeChat-style remark tags and delete flows"`

## Task 4: 私聊聊天信息资料跳转

**Files:**
- Modify: `apps/mobile_flutter/lib/features/matrix/direct_chat_info_page.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`
- Test: `apps/mobile_flutter/test/features/matrix/direct_chat_info_page_test.dart`

- [ ] **Step 1: Write failing widget test**
  - Tap the peer avatar/name region and assert a `ContactProfilePage` route opens; assert no avatar-only preview route is used.
- [ ] **Step 2: Run RED**
  - Run the focused test; expected failure because `_person` is not tappable.
- [ ] **Step 3: Implement**
  - Add `Future<void> Function()? onOpenPeerProfile` to `DirectChatInfoPage`, wrap the person tile in a `CupertinoButton`, and pass the existing contact profile route from `matrix_home_page.dart`.
  - Keep add-member, search-history and preference controls unchanged.
- [ ] **Step 4: Run GREEN and commit**
  - Run focused test and `flutter analyze`; commit `feat(chat): open peer profile from chat info`.

## Task 5: 阶段一综合验证与审查

**Files:**
- Create: `docs/verification/2026-08-23-phase1-ui-review.md`
- Modify: `docs/ui-development-figma-workflow.md` only if required fields are missing

- [ ] **Step 1: Run verification**
  - `C:\srclutterinlutter.bat analyze`
  - `C:\srclutterinlutter.bat test`
  - `python scripts/verify_ui_contract.py`
  - `pwsh -NoProfile -File scripts/verify.ps1`
- [ ] **Step 2: Record Figma review**
  - List exact page/frame IDs, component keys, states, token result, screenshot paths, and developer PASS/FAIL gate.
- [ ] **Step 3: Commit phase one evidence**
  - `git add docs/verification/2026-08-23-phase1-ui-review.md`; `git commit -m "docs(ui): record phase one Figma review"`.

## Task 6: 阶段二搜索与日期选择器

**Files:**
- Modify: `apps/mobile_flutter/lib/features/matrix/chat_history_search.dart`
- Create: `apps/mobile_flutter/lib/ui/components/wechat_date_picker.dart`
- Create: `apps/mobile_flutter/lib/features/search/global_search_page.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/direct_chat_info_page.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/group_chat_info_page.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`
- Test: `apps/mobile_flutter/test/features/matrix/chat_history_search_test.dart`
- Test: `apps/mobile_flutter/test/ui/wechat_date_picker_test.dart`
- Test: `apps/mobile_flutter/test/features/search/global_search_page_test.dart`

- [ ] **Step 1: Write failing tests**
  - Assert date-grouped results, incremental loading, query relevance ordering, highlighted matches, and selected-date filtering.
  - Assert DatePicker has wheel columns, centered cancel/confirm action row, and stable selected value.
- [ ] **Step 2: Run RED**
  - Run the three focused test files; expected failures for missing widgets/models.
- [ ] **Step 3: Implement**
  - Add immutable search result/group models and a paged controller; preserve encrypted local-only message search boundary.
  - Build shared Cupertino wheel picker with WeChat spacing, typography, scrim, spring presentation, and button semantics.
  - Add global search route from message/contact/discovery navigation icons; match friends, groups and local chat records, rank exact > prefix > contains, and highlight query spans.
- [ ] **Step 4: Run GREEN and commit**
  - Run focused tests, `flutter analyze`; commit `feat(search): add WeChat history and global search surfaces`.

## Task 7: 阶段三群成员实时同步

**Files:**
- Modify: `apps/mobile_flutter/lib/features/matrix/group_chat_info_controller.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/group_chat_info_page.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/group_chat_controller.dart`
- Test: `apps/mobile_flutter/test/features/matrix/group_chat_info_test.dart`

- [ ] **Step 1: Write failing tests**
  - Add/remove a member and assert count/list updates without route restart.
  - Assert owner first, up to three administrators next, then remaining members sorted by display name; new members appear in remaining section immediately.
- [ ] **Step 2: Run RED**
  - Run `flutter test test/features/matrix/group_chat_info_test.dart`; expected failure for stale count/list.
- [ ] **Step 3: Implement**
  - Make controller own a reactive member snapshot and expose `replaceMembers`; invoke after add/remove completion and Matrix membership events.
  - Use one stable comparator for owner/admin/other ordering and notify listeners before route rebuild.
- [ ] **Step 4: Run GREEN and commit**
  - Run focused tests, `flutter analyze`; commit `fix(group): refresh chat info members in place`.

## Task 8: Full verification and release record

**Files:**
- Modify: `docs/verification/2026-08-23-chatflow-brand-migration.md`
- Create: `docs/verification/2026-08-23-phase2-ui-review.md`
- Create: `docs/verification/2026-08-23-phase3-ui-review.md`

- [ ] **Step 1: Run full checks**
  - Run `flutter analyze`, `flutter test`, `npm test` in `design-demo`, and `pwsh -NoProfile -File scripts/verify.ps1`.
- [ ] **Step 2: Record Figma evidence**
  - For every phase record ledger IDs, token parity, states and visual QA results.
- [ ] **Step 3: Commit release evidence**
  - `git add docs/verification`; `git commit -m "docs(ui): record phased ChatFlow verification"`.
