# 畅聊 Figma 严格映射、主题控制与 Profile 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 以 Figma 为唯一视觉基准，实现消息“更多”中的持久化三态主题、严格对齐 `60 Profile`，并修复 Discovery/Profile 底部真实图标导航及全 APP Figma 合规缺口。

**Architecture:** 新增独立 `ThemeController` 与非敏感偏好存储，由根 `LiuhetongApp` 解析主题并向下提供；消息页只负责呈现更多/外观面板。Profile 保留既有 Controller 与 API，将首页、详情编辑、头像状态和设置拆成专用展示组件。底部导航仍由 `AppHome` 单一持有，子页只绘制内容。

**Tech Stack:** Flutter 3.44、Dart、Cupertino、shared_preferences 2.5.3、flutter_test、Figma MCP、PowerShell 7、ADB。

---

### Task 1: 建立 Figma 页面—Widget 合同和失败测试

**Files:**
- Create: `docs/verification/figma-mobile-screen-contract.csv`
- Modify: `tests/mobile/test_figma_ui_contract.py`
- Modify: `apps/mobile_flutter/test/widget_test.dart`

- [ ] 记录 10–90 页面、关键 node ID、Flutter route/widget、主题和状态覆盖。
- [ ] 添加静态测试：每个 Figma 模块均存在生产 Widget/入口映射。
- [ ] 添加静态测试：Discovery/Profile 禁止字符图标，主导航只有 `AppHome` 持有。
- [ ] 添加 Widget 测试：消息更多打开底部面板、Profile 首页严格五入口。
- [ ] 运行聚焦测试，确认因缺失主题/结构按预期失败。
- [ ] 提交 Red 证据。

### Task 2: 实现可持久化三态主题控制器

**Files:**
- Modify: `apps/mobile_flutter/pubspec.yaml`
- Modify: `apps/mobile_flutter/pubspec.lock`
- Create: `apps/mobile_flutter/lib/ui/theme/theme_controller.dart`
- Create: `apps/mobile_flutter/test/ui/theme_controller_test.dart`

- [ ] 添加 `shared_preferences: 2.5.3` 显式依赖。
- [ ] 先写默认、system/light/dark、损坏值、保存失败与重启恢复测试。
- [ ] 运行测试并确认失败。
- [ ] 实现 `ThemePreferenceStore`、平台 Store 和 `ThemeController`。
- [ ] 保存失败回滚旧值并暴露稳定错误状态。
- [ ] 运行控制器测试并确认通过。

### Task 3: 根主题注入和消息更多/外观面板

**Files:**
- Modify: `apps/mobile_flutter/lib/main.dart`
- Modify: `apps/mobile_flutter/lib/app_home.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`
- Create: `apps/mobile_flutter/lib/ui/theme/theme_picker_sheet.dart`
- Modify: `apps/mobile_flutter/test/ui/messaging_surfaces_test.dart`
- Modify: `apps/mobile_flutter/test/widget_test.dart`

- [ ] 先写根主题即时刷新和重建恢复 Widget 测试。
- [ ] 将 `LiuhetongApp` 改为消费 `ThemeController`，system 使用平台 brightness，强制模式不受系统变化影响。
- [ ] 将控制器从 `AppHome` 传入消息页；退出登录不销毁偏好。
- [ ] 将 `messages-more` 改为打开与 `30:60` 一致的底部面板。
- [ ] 加入“外观”行及三模式二级面板，使用真实 checkmark 图标和 44px 触控区。
- [ ] 补发起群聊、添加朋友、扫一扫的真实导航/回调，不保留无动作行。
- [ ] 运行聚焦测试并确认通过。

### Task 4: 固定 Discovery/Profile 底部导航并使用真实图标

**Files:**
- Modify: `apps/mobile_flutter/lib/app_home.dart`
- Modify: `apps/mobile_flutter/lib/ui/foundation/changliao_icons.dart`
- Modify: `apps/mobile_flutter/test/widget_test.dart`
- Modify: `tests/mobile/test_figma_ui_contract.py`

- [ ] 写失败测试：393×852 下导航底边与视口/SafeArea 对齐，Discovery/Profile 切换不产生第二导航。
- [ ] 写失败测试：四个导航项是 `Icon`，语义分别为消息、通讯录、发现、我。
- [ ] 将主内容与底部导航改成约束明确的 `Column + Expanded + CupertinoTabBar`。
- [ ] 映射真实消息气泡、联系人、指南针/发现和个人图标。
- [ ] 检查键盘、长内容和深色模式下导航仍固定。
- [ ] 运行聚焦测试并确认通过。

### Task 5: 严格实现 Profile 首页

**Files:**
- Modify: `apps/mobile_flutter/lib/features/profile/profile_page.dart`
- Modify: `apps/mobile_flutter/lib/ui/components/user_identity_header.dart`
- Create: `apps/mobile_flutter/lib/ui/components/profile_menu_tile.dart`
- Modify: `apps/mobile_flutter/test/features/profile/profile_controller_test.dart`
- Create: `apps/mobile_flutter/test/features/profile/profile_page_test.dart`

- [ ] 写失败测试：身份卡 369×126、头像 72、显示畅聊号/签名、点击进入详情。
- [ ] 写失败测试：仅显示朋友圈、彩币、红包、钱包、设置五行，顺序固定。
- [ ] 写失败测试：首页不存在昵称输入、保存、头像上传、恢复默认和退出大按钮。
- [ ] 实现浅色 `29:2169` 与深色 `29:2263` 的 Token、间距、行高和真实图标。
- [ ] 为朋友圈补真实入口回调并连接 `MomentsPage`。
- [ ] 运行 Profile 聚焦测试并确认通过。

### Task 6: 资料详情、编辑与头像状态

**Files:**
- Create: `apps/mobile_flutter/lib/features/profile/profile_details_page.dart`
- Create: `apps/mobile_flutter/lib/features/profile/profile_avatar_page.dart`
- Modify: `apps/mobile_flutter/lib/features/profile/profile_page.dart`
- Modify: `apps/mobile_flutter/lib/features/profile/profile_controller.dart`（仅补展示所需、保持 Gateway 合同）
- Modify: `apps/mobile_flutter/test/features/profile/profile_page_test.dart`

- [ ] 写详情默认/编辑测试，覆盖保存、取消、错误和 loading。
- [ ] 写头像 picker/crop/preview/uploading/failed/permission/fallback/restore-confirm 测试。
- [ ] 实现 `29:1976`、`29:2070` 及八个头像状态的页面组合。
- [ ] 权限拒绝接系统设置；恢复默认要求确认；上传失败可重试。
- [ ] 验证原图不经过 Business API，公开 ProfileGateway 边界不变。
- [ ] 运行 Profile 全部测试并确认通过。

### Task 7: 严格实现 Profile 设置页状态

**Files:**
- Create: `apps/mobile_flutter/lib/features/profile/profile_settings_page.dart`
- Modify: `apps/mobile_flutter/lib/app_home.dart`
- Modify: `apps/mobile_flutter/test/features/profile/profile_page_test.dart`

- [ ] 写设置默认、隐私、退出确认、退出 loading、退出失败测试。
- [ ] 实现账号与隐私、消息通知、减少动态效果、关于畅聊和退出登录的 Figma 顺序。
- [ ] 保持减少动态效果与主题偏好独立。
- [ ] 退出失败显示 Figma toast 并允许重试。
- [ ] 运行聚焦测试并确认通过。

### Task 8: 全 APP Figma 合规审计与缺口修复

**Files:**
- Modify: `docs/verification/figma-mobile-screen-contract.csv`
- Modify: `tests/mobile/test_figma_ui_contract.py`
- Modify: 与审计缺口对应的 `apps/mobile_flutter/lib/features/**` 和 `apps/mobile_flutter/lib/ui/**`

- [ ] 逐页检查 Auth、Messages、Calls、Contacts、Discovery、Profile、Finance、Feedback、Dark Reference。
- [ ] 将不可达入口、无动作按钮、错误数据流列为 P0 并修复。
- [ ] 将缺失 loading/error/empty/modal 状态列为 P1 并修复。
- [ ] 将嵌套、导航、真实图标、Token、间距差异列为 P2 并修复。
- [ ] 每个修复先添加失败测试，再写最小实现。
- [ ] 更新合同矩阵至所有必需项 PASS。

### Task 9: Figma 同步新增主题状态

**Figma:**
- File: `zpzwTbnj1hqx80tyRygX78`
- Page: `20 Messages & Chat`

- [ ] 在原 `messages-new-conversation-sheet` 基础上增加“外观”行。
- [ ] 展开 system/light/dark 三个二级面板状态为独立 393×852 Frame。
- [ ] 使用既有 Token、Auto Layout、真实图标和严格 DOM/图层命名。
- [ ] 截图复核浅色、深色、选中标记、底部 SafeArea 与 Flutter 一致。

### Task 10: 完整验证、模拟器与证据

**Files:**
- Create: `docs/verification/2026-08-17-figma-strict-ui-theme-profile.md`
- Modify: `docs/superpowers/plans/2026-08-17-figma-strict-ui-theme-profile.md`

- [ ] 运行 `dart format --output=none --set-exit-if-changed`。
- [ ] 运行 `flutter analyze` 和完整 `flutter test`。
- [ ] 运行移动端静态合同和 `scripts/verify.ps1`。
- [ ] 构建 x64 APK 并覆盖安装到在线雷电模拟器。
- [ ] 验证三主题即时切换、重启保持、Discovery/Profile 底部导航、Profile 主流程和日志无 fatal。
- [ ] 记录 Figma 节点、Red/Green、测试数量、截图、规范审查与安全边界。
- [ ] 将计划复选框全部完成并提交实现。