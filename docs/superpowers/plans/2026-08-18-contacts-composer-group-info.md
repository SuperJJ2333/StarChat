# 通讯录滚动、聊天发送态与群聊信息实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 严格同步通讯录下拉行为、Emoji 发送态和完整群聊信息体验到 Figma 与 Flutter。

**Architecture:** 根页面滚动行为由共享的可回弹导航表面组件承载；Composer 状态由纯状态对象决定；群聊规则与 Matrix 操作封装进独立 controller/gateway，页面只负责渲染与导航。Figma 在原 `20 Messages & Chat` 区域按 393 × 852 独立状态 Frame 归档。

**Tech Stack:** Flutter/Dart、matrix 0.34.0、flutter_test、Figma Plugin API、PowerShell/ADB。

## Global Constraints

- 采用 A．原始节点严格映射。
- iPhone 15 基准为 393 × 852px，1 CSS px = 1 Figma px。
- 产品可见名称统一为“畅聊”；内部包名、Matrix ID 与技术标识保持不变。
- Matrix 房间继续强制 E2EE；本地隐藏不得变成服务端撤回或删除。

---

### Task 1: 通讯录统一下拉表面

**Files:**
- Modify: `apps/mobile_flutter/lib/features/contacts/contacts_page.dart`
- Test: `apps/mobile_flutter/test/features/contacts/contact_flow_test.dart`

- [x] 写 393 × 852 overscroll Widget 红灯测试，断言联系人内容与右侧索引共同下移且根导航不移动。
- [x] 运行 focused test，确认因现有索引独立定位而失败。
- [x] 将通讯录改为同一可回弹内容表面并保持索引定位、分组和 TabBar 约束。
- [x] 运行 focused test 并格式化。

### Task 2: Emoji 与文本统一发送态

**Files:**
- Modify: `apps/mobile_flutter/lib/ui/chat/chat_composer_state.dart`
- Modify: `apps/mobile_flutter/lib/ui/chat/chat_composer_bar.dart`
- Test: `apps/mobile_flutter/test/ui/chat_composer_bar_test.dart`

- [x] 写无焦点 Emoji 也显示发送及发送容器 pressed 色的红灯测试。
- [x] 运行测试，确认现有 `focused && hasText` 和透明按钮导致失败。
- [x] 改为 `hasText` 决定发送态，并给发送按钮增加 `brand/pressed` 背景和对比前景。
- [x] 运行 focused test 并格式化。

### Task 3: 群聊人数和默认名称规则

**Files:**
- Modify: `apps/mobile_flutter/lib/features/matrix/group_chat_controller.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/group_chat_page.dart`
- Test: `apps/mobile_flutter/test/features/matrix/group_chat_controller_test.dart`

- [x] 写少于两名受邀者拒绝、默认前三成员名、20 字截断的红灯测试。
- [x] 运行测试并确认失败原因来自旧规则。
- [x] 实施总人数至少三人、稳定成员顺序和字符级 20 字限制。
- [x] 运行 focused test 并格式化。

### Task 4: Matrix 群聊信息控制器与页面

**Files:**
- Create: `apps/mobile_flutter/lib/features/matrix/group_chat_info_controller.dart`
- Create: `apps/mobile_flutter/lib/features/matrix/group_chat_info_page.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`
- Test: `apps/mobile_flutter/test/features/matrix/group_chat_info_test.dart`

- [x] 写 controller 红灯测试，覆盖成员计数、折叠数量、名称/公告/备注、添加成员与退出群聊。
- [x] 写页面红灯测试，覆盖 `聊天信息(n)`、末位添加图标和功能顺序。
- [x] 实施 Matrix gateway 与账号房间设置，接入群聊 Chat 右上角更多入口。
- [x] 实施微信式分组页面、成员选择、编辑页与错误反馈。
- [x] 运行 focused tests 并格式化。

### Task 5: Figma 原模块状态扩展

**Files:**
- Modify: Figma file `zpzwTbnj1hqx80tyRygX78`

- [x] 在 `20 Messages & Chat` 区域创建七个独立 393 × 852 Frame。
- [x] 使用现有 Token、真实图标字体和严格层级构建群聊 Chat、详情、展开、选择、编辑与搜索状态。
- [x] 对每个 Frame 获取截图，校验字体、颜色、尺寸、裁切和顺序。

### Task 6: 全量验证与模拟器

**Files:**
- Create: `docs/verification/2026-08-18-contacts-composer-group-info.md`

- [x] 运行 `dart format --output=none --set-exit-if-changed lib test`。
- [x] 运行 focused tests、`flutter test` 和 `flutter analyze`。
- [x] 运行 `pwsh -NoProfile -File scripts/verify.ps1`。
- [x] 构建 Debug APK，安装至在线雷电模拟器并保存安装运行截图。
- [x] 记录红绿灯、Figma node IDs、测试、APK 和 ADB 证据，完成规格与质量复审。
