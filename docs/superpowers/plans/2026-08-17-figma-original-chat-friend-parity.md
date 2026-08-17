# Figma Original Chat and Friend Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Flutter Chat、好友资料和 Figma 缺失状态恢复为原始节点严格映射，并消除更多面板溢出与 Emoji 无效操作。

**Architecture:** 以现有 WeChat Token 作为 Figma 变量到 Flutter 的唯一映射层；Chat 面板使用确定高度的响应式四列网格；好友资料用专用 section widget 重现节点 `35:63`。Figma 只在原始 Messages 模块旁补交互状态，不复制新的页面。

**Tech Stack:** Flutter/Dart、Cupertino widgets、emoji_picker_flutter、Figma Plugin API、flutter_test、ADB

## Global Constraints

- 基准宽度 393px，1 CSS/Figma px = 1 Flutter logical px。
- 浅色 Chat 背景 `#EDEDED`，导航/输入栏 `#F7F7F7`，输入与卡片 `#FFFFFF`。
- 保持 Matrix E2EE 与业务 API 边界不变。
- 不修改内部代码标识、包名、Matrix ID 或资产代码。

---

### Task 1: 回归测试红灯

**Files:**
- Modify: `apps/mobile_flutter/test/ui/chat_more_panel_test.dart`
- Modify: `apps/mobile_flutter/test/ui/chat_emoji_panel_test.dart`
- Modify: `apps/mobile_flutter/test/features/contacts/contact_flow_test.dart`
- Modify: `apps/mobile_flutter/test/ui/messaging_surfaces_test.dart`

- [x] **Step 1:** 增加 393px/1.3 倍文字缩放无 overflow、Emoji 无搜索/退格、Chat 背景 Token、好友页原始尺寸与纵向排列断言。
- [x] **Step 2:** 运行四个目标测试，确认分别因现有溢出、默认 action bar、好友横向布局或缺少结构 key 失败。

### Task 2: Flutter 原始节点映射

**Files:**
- Modify: `apps/mobile_flutter/lib/ui/chat/chat_more_panel.dart`
- Modify: `apps/mobile_flutter/lib/ui/chat/chat_emoji_panel.dart`
- Modify: `apps/mobile_flutter/lib/features/contacts/contact_profile_sections.dart`
- Modify: `apps/mobile_flutter/lib/features/contacts/contacts_page.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`

- [x] **Step 1:** 用确定 `mainAxisExtent` 的四列网格修复更多面板，并给面板和单元添加稳定 key。
- [x] **Step 2:** 禁用 EmojiPicker 默认底部 action bar 与搜索入口，仅保留产品自己的三段导航。
- [x] **Step 3:** 将好友身份卡、朋友圈和操作区恢复为 `35:63` 的 126/120/48px 结构与纵向操作按钮；窄于 393px 时朋友圈预览按可用宽度收缩。
- [x] **Step 4:** 通过 root Navigator 打开 Chat 与好友资料，覆盖首页 TabBar；固定 Chat Figma Token，运行目标测试至绿灯。

### Task 3: Figma 原始 Messages 模块补帧

**Files:**
- Modify: Figma file `zpzwTbnj1hqx80tyRygX78`
- Modify: `design-demo/artifacts/figma-state.json`

- [x] **Step 1:** 检查原始 Messages 区域边界和现有状态 Frame，避免重名与覆盖。
- [x] **Step 2:** 将原有补充画廊整理为正式 `20 Messages & Chat / Complete Interaction States / Original Mapped`，补齐普通文本和图片/GIF两种菜单并移除与 `35:63` 冲突的推测版好友重复画板。
- [x] **Step 3:** 截图检查 `#EDEDED/#F7F7F7/#FFFFFF`、393 × 852、无裁切，并保存新增 node ID。

### Task 4: 验证与模拟器交付

**Files:**
- Create: `docs/verification/2026-08-17-figma-original-chat-friend-parity.md`
- Modify: `docs/superpowers/plans/2026-08-17-figma-original-chat-friend-parity.md`

- [x] **Step 1:** 运行 `dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、目标测试和完整 `flutter test`。
- [x] **Step 2:** 运行 `pwsh -NoProfile -File scripts/verify.ps1`。
- [x] **Step 3:** 构建 Debug APK、记录 SHA-256，通过 `adb install -r` 重装并启动。
- [x] **Step 4:** 记录 Figma node IDs、测试结果、APK Hash、模拟器 serial 与冒烟证据。

## Self-review

- 规格中的 Chat 色彩、更多面板、Emoji、好友资料、Figma 补帧和交付验证均有对应任务。
- 生产代码修改前必须先观察目标测试按预期失败。
- 不引入新服务契约、金融状态变更或 E2EE 边界变更。
