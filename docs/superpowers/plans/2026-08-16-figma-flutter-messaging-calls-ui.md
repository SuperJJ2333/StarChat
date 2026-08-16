# 畅聊 Figma → Flutter 消息、聊天与通话 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将已批准 Figma 中的消息列表、混合聊天与一对一音视频通话代表状态落实为真实可运行的 Flutter UI，同时完整保留现有 Matrix E2EE、时间线、媒体上传和 WebRTC 控制器边界。

**Architecture:** 视图层新增三个小型、纯展示组件：会话行、聊天输入区和通话控制面板；页面继续消费现有 `MatrixSdkE2eeClient`、`RoomTimelineController`、`MediaMessageService` 与 `CallController`。Figma 节点 `30:2`、`30:31`、`29:996` 是视觉基准，状态只从现有领域对象派生，不在 Widget 中复制通信状态机。

**Tech Stack:** Flutter/Dart、Cupertino widgets、Matrix SDK、flutter_webrtc、现有语义 Token/图标、Flutter widget tests、Python 静态设计契约。

---

## File Map

- `apps/mobile_flutter/lib/ui/components/conversation_list_tile.dart`：固定 Leading/Body/Trailing 结构、48px 头像、时间、静音和未读徽章。
- `apps/mobile_flutter/lib/ui/chat/chat_composer_bar.dart`：附件、语音、文本和发送四个稳定插槽；只通过回调触发既有业务行为。
- `apps/mobile_flutter/lib/ui/components/call_control_button.dart`：72px 圆形通话控件及语义标签。
- `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`：真实房间列表与房间时间线的 Figma 布局适配。
- `apps/mobile_flutter/lib/features/matrix/call_page.dart`：现有 RTC Renderer/Controller 的 Figma 通话表面适配。
- `apps/mobile_flutter/lib/ui/foundation/changliao_icons.dart`：补齐更多、附件、静音、扬声器、挂断、镜头切换等语义图标。
- `apps/mobile_flutter/lib/ui/foundation/wechat_tokens.dart`：会话行、头像、Composer 与通话控件尺寸 Token。
- `apps/mobile_flutter/test/ui/messaging_surfaces_test.dart`：三个纯展示组件的结构、尺寸、状态和交互测试。
- `apps/mobile_flutter/test/features/matrix/call_page_test.dart`：来电、通话中、静音与结束状态的页面测试。
- `tests/mobile/test_figma_ui_contract.py`：Figma 节点、稳定 Key、语义图标与控制器边界的静态门禁。
- `docs/verification/2026-08-16-figma-flutter-messaging-calls-ui.md`：Red/Green、Figma 映射和全仓验证证据。

### Task 1: 固化 Figma 与代码结构契约

- [x] **Step 1: 写失败的静态设计契约**

扩展 `tests/mobile/test_figma_ui_contract.py`，要求三个新组件文件存在；`MatrixHomePage` 使用 `ConversationListTile`；`RoomPage` 使用 `ChatComposerBar`；`CallPage` 使用 `CallControlButton`；所有页面保留现有 Matrix/Call 控制器调用而不引入模拟数据。

- [x] **Step 2: 运行并确认 Red**

```powershell
$env:PYTHONUTF8='1'; $env:PYTHONIOENCODING='utf-8'
python -m pytest tests/mobile/test_figma_ui_contract.py -q
```

Expected: FAIL，原因是新组件和稳定 Key 尚不存在。

- [x] **Step 3: 写失败的 Flutter 展示组件测试**

创建 `messaging_surfaces_test.dart`，断言：会话行高度至少 72、头像 48、未读 `99+`；Composer 具有四个稳定 Key 且发送回调有效；通话按钮为 72×72、图标来自 `ChangliaoIcons`、Semantics 标签可读。

### Task 2: 实现会话列表视觉切片

- [x] **Step 1: 增加 Token 与语义图标**

新增 `conversationTileHeight = 72.0`、`conversationAvatar = 48.0`、`composerMinHeight = 56.0`、`callControl = 72.0`，以及 `more`、`attachment`、`muted`、`speaker`、`hangup`、`switchCamera`、`close` 图标。

- [x] **Step 2: 最小实现 `ConversationListTile`**

组件构造参数固定为 `title`、`subtitle`、`timeLabel`、`avatar`、`unreadCount`、`muted`、`onTap`；DOM 等价 Widget 树固定为 `Row(Leading, Expanded(Body), Trailing)`，Trailing 内固定时间与徽章/静音状态。

- [x] **Step 3: 运行组件测试并确认 Green**

```powershell
C:\src\flutter\bin\flutter.bat test test/ui/messaging_surfaces_test.dart
```

Expected: PASS。

- [x] **Step 4: 将真实 Matrix 房间映射到 Figma 节点 `30:2`**

`MatrixHomePage` 使用全宽白色列表、48px `UserAvatar`、标题/最后事件/时间和 `99+`；空态显示图标、标题“暂无消息”和说明；导航栏保留“消息”并增加 `more` 语义按钮。房间点击仍创建真实 `RoomPage`。

### Task 3: 实现聊天时间线与 Composer

- [x] **Step 1: 最小实现 `ChatComposerBar`**

组件接受 `TextEditingController`、`onAttachment`、`onVoice`、`onSend`、`onSubmitted`；固定顺序为附件、语音、文本字段、发送。每个图标触控区至少 44px，输入条最小 56px，使用 `ChangliaoIcons` 和现有 Token。

- [x] **Step 2: 将 `RoomPage` 映射到 Figma 节点 `30:31`**

保持 `RoomTimelineController` 加载、已读、发送、重试、媒体与语音流程；页面背景使用 Light/Dark Token，导航栏增加语音/视频入口图标，消息区采用 12px 横向与 8px 垂直节奏，空态与加载态独立呈现，底部使用 `ChatComposerBar`。

- [x] **Step 3: 补充 RoomPage 静态边界断言并运行 focused tests**

```powershell
$env:PYTHONUTF8='1'; $env:PYTHONIOENCODING='utf-8'
python -m pytest tests/mobile/test_figma_ui_contract.py tests/mobile/test_flutter_boundaries.py -q
C:\src\flutter\bin\flutter.bat test test/ui/messaging_surfaces_test.dart test/features/matrix/room_timeline_controller_test.dart
```

Expected: PASS。

### Task 4: 实现 Figma 一对一音视频通话表面

- [x] **Step 1: 写失败的 CallPage Widget 测试**

在 `call_page_test.dart` 使用现有 fake permissions/backend，断言：来电显示“畅聊加密来电”、接听/拒绝；已连接显示“端到端加密”、麦克风/挂断/扬声器；静音切换后图标和文案更新；视频状态显示摄像头/切换镜头；结束状态显示关闭。

- [x] **Step 2: 运行并确认 Red**

```powershell
C:\src\flutter\bin\flutter.bat test test/features/matrix/call_page_test.dart
```

Expected: FAIL，原因是当前页面结构与 Figma 状态文案/控件不一致。

- [x] **Step 3: 实现 `CallControlButton`**

固定 72×72 圆形触控区，支持 `normal`、`danger`、`accept` 三种视觉状态；按钮必须同时有真实图标、可见文字和 Semantics，禁止 Emoji/Unicode 伪图标。

- [x] **Step 4: 将 `CallPage` 映射到 Figma 节点 `29:996`**

语音页使用 `#191919` 深色通话背景、72px 头像、22px 标题和 14px 状态；已连接展示“端到端加密”。来电在底部显示接听/拒绝；活动通话显示麦克风、挂断、扬声器，视频额外显示镜头切换并保留真实 `RTCVideoView`。权限失败/结束使用已有状态消息和关闭按钮。

- [x] **Step 5: 运行 CallPage 与控制器测试并确认 Green**

```powershell
C:\src\flutter\bin\flutter.bat test test/features/matrix/call_page_test.dart test/features/matrix/call_controller_test.dart
```

Expected: PASS。

### Task 5: 规格审查、质量审查与交付证据

- [x] **Step 1: 运行格式、静态分析与 Flutter 全量测试**

```powershell
C:\src\flutter\bin\dart.bat format --output=none --set-exit-if-changed `
  apps/mobile_flutter/lib/app_home.dart `
  apps/mobile_flutter/lib/features/matrix/call_page.dart `
  apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart `
  apps/mobile_flutter/lib/ui/chat/chat_composer_bar.dart `
  apps/mobile_flutter/lib/ui/components/call_control_button.dart `
  apps/mobile_flutter/lib/ui/components/conversation_list_tile.dart `
  apps/mobile_flutter/lib/ui/foundation/changliao_icons.dart `
  apps/mobile_flutter/lib/ui/foundation/wechat_tokens.dart `
  apps/mobile_flutter/test/features/matrix/call_page_test.dart `
  apps/mobile_flutter/test/ui/messaging_surfaces_test.dart
C:\src\flutter\bin\flutter.bat analyze
C:\src\flutter\bin\flutter.bat test
```

Expected: format/analyze PASS，Flutter tests 全部 PASS。

- [x] **Step 2: 运行全仓验证**

```powershell
pwsh.exe -NoProfile -File scripts/verify.ps1
```

Expected: 所有 Repository、API、Worker、Flutter boundary 门禁 PASS。

- [x] **Step 3: 写验证证据**

在验证文件记录 Figma 节点、Red/Green 命令与结果、测试数量、规格符合性审查和质量/安全审查。明确说明未修改 Matrix E2EE、CallController、WebRTC 信令、业务 API 或金融域。

- [x] **Step 4: 提交阶段成果**

```powershell
git add -- apps/mobile_flutter tests/mobile docs/superpowers/plans docs/verification
git commit -m "feat(mobile): implement figma messaging and call surfaces"
git status --short
```

Expected: 工作树 clean。
