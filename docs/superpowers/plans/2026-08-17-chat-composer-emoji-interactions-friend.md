# 畅聊聊天输入、表情、消息交互与好友页实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将已批准的 Figma 聊天输入、表情仓库、消息操作、同步提醒、头像手势与好友页严格映射为可测试的 Flutter 功能。

**Architecture:** 用纯 UI 状态控制器驱动输入栏和面板互斥；Matrix 适配器只处理加密通信域，设备本地隐藏记录独立存储；好友资料继续通过 `ContactsGateway` 调用业务 API。先完成不依赖服务器契约的 UI 与能力判定，再接入加密仓库、Redaction、提醒和 mentions。

**Tech Stack:** Flutter/Cupertino、Matrix Dart SDK、`emoji_picker_flutter`、`flutter_local_notifications`、SharedPreferences、Flutter Widget/Unit/Golden tests。

## Global Constraints

- 设计基准固定为 393 × 852；触控目标不小于 44 × 44 logical px。
- Matrix 不得成为身份、账本、钱包或红包权威来源。
- 删除只影响当前设备；撤回才调用 Matrix Redaction。
- 只有图片/GIF消息显示“添加到表情”；撤回窗口使用服务器时间且为 2 分钟。
- 表情媒体、提醒定义、拍一拍和个人配置通过 Matrix E2EE 同步，不发送明文附件或明文消息给服务器。
- 所有生产代码遵循 test-first 红—绿—重构；每个任务结束运行 focused tests 并提交。

---

### Task 1: 聊天输入状态机与 Figma 顺序

**Files:**
- Create: `apps/mobile_flutter/lib/ui/chat/chat_composer_state.dart`
- Modify: `apps/mobile_flutter/lib/ui/chat/chat_composer_bar.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`
- Create: `apps/mobile_flutter/test/ui/chat_composer_bar_test.dart`

**Interfaces:**
- Produces: `enum ComposerPanel { none, voice, emoji, more }`
- Produces: `ChatComposerState({required bool focused, required bool hasText, required ComposerPanel panel})`
- Produces: `bool get showsSend`，仅 `focused && hasText` 为真。
- `ChatComposerBar` 固定接收 `onVoice`、`onEmoji`、`onMore`、`onSend`，并使用规格中的六个 key。

- [ ] **Step 1: 写状态机和 Widget 失败测试**，断言 DOM 顺序为 voice → input → emoji → more/send，输入聚焦且有文字时 `composer-more` 消失、`composer-send` 出现，并断言四个触控目标至少 44 px。
- [ ] **Step 2: 运行红灯**：`flutter test test/ui/chat_composer_bar_test.dart`，预期因 `chat_composer_state.dart` 不存在及旧附件顺序失败。
- [ ] **Step 3: 最小实现状态模型与输入栏**；使用 `FocusNode` 和 controller listener 刷新状态，输入框占据剩余宽度，more/send 共用末端位置。
- [ ] **Step 4: 接入 `RoomPage`**，把旧 `onAttachment` 改为 `onMore`，文本发送后保留焦点并清理输入。
- [ ] **Step 5: 运行绿灯**：`flutter test test/ui/chat_composer_bar_test.dart test/ui/wechat_components_test.dart`。
- [ ] **Step 6: 提交**：`git commit -m "feat(mobile): align chat composer with figma"`。

### Task 2: 更多功能面板与表情选择器

**Files:**
- Modify: `apps/mobile_flutter/pubspec.yaml`
- Modify: `apps/mobile_flutter/pubspec.lock`
- Create: `apps/mobile_flutter/lib/ui/chat/chat_more_panel.dart`
- Create: `apps/mobile_flutter/lib/ui/chat/chat_emoji_panel.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`
- Create: `apps/mobile_flutter/test/ui/chat_more_panel_test.dart`
- Create: `apps/mobile_flutter/test/ui/chat_emoji_panel_test.dart`

**Interfaces:**
- Produces: `ChatMoreAction`：image、camera、voiceCall、videoCall、redPacket、file。
- Produces: `ChatEmojiPanel(onEmojiSelected, recent, customItems, onCustomSelected)`。
- Consumes: `ComposerPanel`，确保系统键盘、voice、emoji、more 互斥。

- [ ] **Step 1: 写失败测试**，断言 4 列网格完整显示六项真实 Icon，表情页存在“最近/全部/我的表情”，GIF 使用保持动画的 `Image`。
- [ ] **Step 2: 运行红灯**：`flutter test test/ui/chat_more_panel_test.dart test/ui/chat_emoji_panel_test.dart`。
- [ ] **Step 3: 固定兼容版本的 `emoji_picker_flutter` 并执行 `flutter pub get`**；不得把 Unicode 表情列表写回页面代码。
- [ ] **Step 4: 实现两个面板并替换 `_showMedia`/`_showEmoji` 弹窗**；图片、拍摄、语音、视频、红包、文件调用现有公开回调。
- [ ] **Step 5: 运行绿灯与 analyze**：`flutter test test/ui/chat_more_panel_test.dart test/ui/chat_emoji_panel_test.dart && flutter analyze`。
- [ ] **Step 6: 提交**：`git commit -m "feat(mobile): add chat more and emoji panels"`。

### Task 3: Matrix 私有加密表情仓库

**Files:**
- Create: `apps/mobile_flutter/lib/features/matrix/emoji_vault.dart`
- Create: `apps/mobile_flutter/lib/features/matrix/matrix_emoji_vault.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/media_message_service.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`
- Create: `apps/mobile_flutter/test/features/matrix/emoji_vault_test.dart`

**Interfaces:**
- Produces: `EmojiVaultItem(id, sha256, mimeType, encryptedFile, createdAt, isAnimated)`。
- Produces: `EmojiVault.list/add/remove/markRecent`；`add` 先在设备端 SHA-256 去重。
- Matrix 事件只使用 `com.changliao.emoji.add`、`.remove`、`.recents`，且房间必须开启 E2EE。

- [ ] **Step 1: 写失败测试**，覆盖 SHA-256 去重、乱序事件合并、删除 tombstone、最近使用稳定合并，以及拒绝未加密房间。
- [ ] **Step 2: 运行红灯**：`flutter test test/features/matrix/emoji_vault_test.dart`。
- [ ] **Step 3: 实现纯 Dart 合并模型**，不依赖 Widget 或业务 API。
- [ ] **Step 4: 实现 Matrix 适配器**，复用现有加密上传能力；账号数据只保存仓库 room ID，不保存表情明文或密钥。
- [ ] **Step 5: 接入图片/GIF“添加到表情”与我的表情页**，同步错误显示可重试状态。
- [ ] **Step 6: 运行绿灯并提交**：`flutter test test/features/matrix/emoji_vault_test.dart`；`git commit -m "feat(mobile): sync encrypted custom emoji vault"`。

### Task 4: 消息菜单能力矩阵与本地删除

**Files:**
- Create: `apps/mobile_flutter/lib/ui/chat/message_action.dart`
- Create: `apps/mobile_flutter/lib/ui/chat/message_action_sheet.dart`
- Create: `apps/mobile_flutter/lib/features/matrix/local_hidden_events.dart`
- Modify: `apps/mobile_flutter/lib/ui/chat/wechat_message_bubble.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/room_timeline_controller.dart`
- Create: `apps/mobile_flutter/test/ui/message_action_sheet_test.dart`
- Create: `apps/mobile_flutter/test/features/matrix/local_hidden_events_test.dart`

**Interfaces:**
- Produces: `MessageActionPolicy.actionsFor(MessageCapabilities)`。
- Produces: `LocalHiddenEvents.hide(roomId,eventId)` 与 `isHidden`；不得调用 Matrix send/redact。

- [ ] **Step 1: 写失败测试**，逐类型断言菜单能力，特别断言文本消息没有“添加到表情”、图片/GIF有；删除后当前设备过滤事件且 fake Matrix client 零调用。
- [ ] **Step 2: 运行红灯**：运行上述两个测试文件。
- [ ] **Step 3: 实现能力策略、长按菜单和本地隐藏存储**；存储键按账号和 room ID 隔离。
- [ ] **Step 4: 接入多选模式、批量转发和批量本地删除**；红包和系统控制事件禁止转发。
- [ ] **Step 5: 运行绿灯并提交**：`git commit -m "feat(mobile): add typed message actions and local delete"`。

### Task 5: 引用、转发、两分钟撤回与 @ mentions

**Files:**
- Create: `apps/mobile_flutter/lib/features/matrix/message_interaction_service.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_client_adapter.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`
- Modify: `apps/mobile_flutter/lib/ui/chat/wechat_message_bubble.dart`
- Create: `apps/mobile_flutter/test/features/matrix/message_interaction_service_test.dart`

**Interfaces:**
- Produces: `canRecall(event, serverNow)`；仅本人发送且 `serverNow - originServerTs <= 2 minutes`。
- Produces: `reply(eventId,text)`、`forward(event,targetRoom)`、`recall(eventId,reason)`、`sendMention(text,userIds)`。

- [ ] **Step 1: 写失败测试**，覆盖 1:59 可撤回、2:01 不可撤回、他人消息不可撤回、Redaction 只调用一次、reply relation 和 `m.mentions.user_ids`。
- [ ] **Step 2: 运行红灯**：`flutter test test/features/matrix/message_interaction_service_test.dart`。
- [ ] **Step 3: 实现最小服务并接入菜单**；转发时在目标房间重新加密，严禁复制密钥或原始密文。
- [ ] **Step 4: 长按头像插入 `@显示名` 并保存 Matrix 用户 ID**；取消/编辑提及后同步更新 ID 集合。
- [ ] **Step 5: 运行绿灯并提交**：`git commit -m "feat(mobile): add reply forward recall and mentions"`。

### Task 6: 拍一拍与跨设备同步提醒

**Files:**
- Modify: `apps/mobile_flutter/pubspec.yaml`
- Modify: `apps/mobile_flutter/pubspec.lock`
- Create: `apps/mobile_flutter/lib/features/matrix/nudge_service.dart`
- Create: `apps/mobile_flutter/lib/features/matrix/message_reminder_service.dart`
- Create: `apps/mobile_flutter/lib/core/local_notification_scheduler.dart`
- Modify: `apps/mobile_flutter/lib/ui/chat/wechat_message_bubble.dart`
- Create: `apps/mobile_flutter/test/features/matrix/nudge_service_test.dart`
- Create: `apps/mobile_flutter/test/features/matrix/message_reminder_service_test.dart`

**Interfaces:**
- Produces: `NudgeService.send(targetUserId,suffix)`，事件类型 `com.changliao.nudge`。
- Produces: `MessageReminder(id,roomId,eventId,dueAt,status)`；每台同步设备调用 `LocalNotificationScheduler.schedule`。

- [ ] **Step 1: 写失败测试**，双击头像只发送一次 nudge；提醒事件加密同步、同 ID 幂等、取消通知、离线过期后提示。
- [ ] **Step 2: 运行红灯**：运行两个服务测试。
- [ ] **Step 3: 固定兼容版本 `flutter_local_notifications` 并实现本地 scheduler**；通知正文只使用通用文案。
- [ ] **Step 4: 实现加密提醒控制房间合并和拍一拍后缀配置同步**。
- [ ] **Step 5: 接入双击头像、提醒时间选择器和时间线系统气泡**。
- [ ] **Step 6: 运行绿灯并提交**：`git commit -m "feat(mobile): sync nudges and message reminders"`。

### Task 7: 好友资料与好友设置严格映射

**Files:**
- Modify: `apps/mobile_flutter/lib/features/contacts/contacts_page.dart`
- Create: `apps/mobile_flutter/lib/features/contacts/contact_profile_sections.dart`
- Modify: `apps/mobile_flutter/test/features/contacts/contact_flow_test.dart`

**Interfaces:**
- `ContactProfilePage` 标题固定“好友资料”，包含身份卡、朋友圈预览、消息/语音/视频三项真实图标操作。
- `ContactMorePage` 标题固定“好友设置”，行顺序固定为备注、标签、朋友圈权限、黑名单、删除好友。

- [ ] **Step 1: 写失败 Widget 测试**，断言标题、列表顺序、真实 Icon、开关语义、删除二次确认和回调导航。
- [ ] **Step 2: 运行红灯**：`flutter test test/features/contacts/contact_flow_test.dart`，预期旧“更多”和纵向大按钮结构失败。
- [ ] **Step 3: 以 `CupertinoListSection` 和小型专用 section widget 最小重构两个页面**；保持现有 `ContactsGateway` 调用不变。
- [ ] **Step 4: 运行 393 × 852 浅色/深色 Widget 测试**，修复任何 overflow。
- [ ] **Step 5: 运行绿灯并提交**：`git commit -m "feat(mobile): map friend screens to figma"`。

### Task 8: 全量验证、模拟器安装与证据

**Files:**
- Create: `docs/verification/2026-08-17-chat-emoji-friend-verification.md`
- Modify: `docs/superpowers/plans/2026-08-17-chat-composer-emoji-interactions-friend.md`

**Interfaces:**
- 记录 Figma gallery node `107:3` 及各 screen ID、测试命令、APK SHA-256、雷电模拟器 serial 和冒烟结果。

- [ ] **Step 1: 运行格式化、analyze、全部 Flutter 测试**：`dart format --output=none --set-exit-if-changed lib test`; `flutter analyze`; `flutter test`。
- [ ] **Step 2: 运行仓库验证**：仓库存在时执行 `pwsh -NoProfile -File scripts/verify.ps1`，完整保存成功或失败输出摘要。
- [ ] **Step 3: 构建 APK 并计算 SHA-256**：`flutter build apk --debug`; `Get-FileHash build/app/outputs/flutter-apk/app-debug.apk -Algorithm SHA256`。
- [ ] **Step 4: 通过 `adb devices` 识别雷电模拟器，安装 `adb install -r`，启动畅聊并执行登录—消息—好友资料—表情—主题冒烟流程。
- [ ] **Step 5: 写验证证据并勾选本计划已完成任务**，不得把 token、密码、Matrix 密钥或聊天明文写入证据。
- [ ] **Step 6: 最终提交**：`git commit -m "test(mobile): verify chat interaction delivery"`。

## Self-review

- 规格第 2 节由 Task 1–2 覆盖；第 3 节由 Task 2–3 覆盖；第 4 节由 Task 4–6 覆盖；第 5 节由 Task 7 覆盖；主题、测试和证据由 Task 7–8 覆盖。
- 计划中所有生产行为都有先失败后实现的明确测试步骤，没有跨模块直写数据库。
- `MessageActionPolicy`、`LocalHiddenEvents`、`MessageInteractionService`、`EmojiVault` 与提醒接口在首次出现处定义，后续命名保持一致。

