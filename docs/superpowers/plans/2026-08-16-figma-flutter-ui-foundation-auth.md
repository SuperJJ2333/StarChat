# 畅聊 Figma → Flutter 基础、认证与主导航 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将已批准 Figma 的视觉 Token、真实图标、登录、注册及四栏主导航落实为可运行 Flutter 代码，保持现有业务 API、Matrix、E2EE 和资产边界不变。

**Architecture:** 本阶段只建立跨模块 UI 基座和第一条可运行纵向切片。Figma 的 `10 Auth` 是认证唯一设计来源；Flutter 使用现有 Cupertino 技术栈、语义 Token 和可测试组件，不复制 HTML DOM，也不改变控制器和网关接口。

**Tech Stack:** Flutter/Dart、Cupertino widgets、`cupertino_icons`、现有 Business API/Matrix 客户端、Flutter widget tests、Python 静态边界测试。

---

## File Map

- `apps/mobile_flutter/lib/ui/foundation/wechat_tokens.dart`：Figma Light/Dark 语义颜色、尺寸、圆角、阴影和动画 Token。
- `apps/mobile_flutter/lib/ui/foundation/changliao_icons.dart`：消息、通讯录、发现、我、语音和视频等语义图标注册表。
- `apps/mobile_flutter/lib/ui/components/auth_surface_card.dart`：认证页白色浮层、品牌标记和字段外观。
- `apps/mobile_flutter/lib/ui/components/immersive_auth_scaffold.dart`：固定背景与键盘避让边界。
- `apps/mobile_flutter/lib/features/auth/login_page.dart`：`10 Auth / auth-login-*` 的真实登录状态。
- `apps/mobile_flutter/lib/features/auth/registration_page.dart`：`10 Auth / auth-registration-*` 的真实注册状态。
- `apps/mobile_flutter/lib/app_home.dart`：四栏主导航的语义图标和 44px 触控区域。
- `apps/mobile_flutter/lib/main.dart`：用户可见品牌改为“畅聊”，内部类名和包名保持不变。
- `apps/mobile_flutter/test/features/auth/auth_pages_test.dart`：认证结构、文案、交互和状态测试。
- `apps/mobile_flutter/test/ui/wechat_theme_test.dart`：Token、图标和主题测试。
- `tests/mobile/test_figma_ui_contract.py`：无 Flutter SDK 环境也可执行的设计契约门禁。
- `docs/verification/2026-08-16-figma-flutter-ui-foundation-auth.md`：红绿测试、Figma 节点和验证证据。

### Task 1: 归一化 Figma 认证页面与交付台账

- [x] **Step 1: 删除重复页面**

在 Figma 文件 `zpzwTbnj1hqx80tyRygX78` 删除 `09 登录与注册`，验证原有 `10 Auth`（节点 `18:6`）仍包含 24 个认证状态。

- [x] **Step 2: 同步本地规格和状态台账**

删除 `figma-state.json` 中 `authReview` 和已删除 Frame ID，移除独立认证页 QA 图片引用，规格统一描述 `10 Auth`。

- [x] **Step 3: 提交 Figma 归一化记录**

```powershell
git add -- design-demo/artifacts/figma-state.json docs/superpowers docs/verification
git commit -m "docs(figma): keep authentication states on 10 Auth"
```

### Task 2: 建立可执行 Flutter 设计契约

- [x] **Step 1: 写失败的静态设计契约测试**

在 `tests/mobile/test_figma_ui_contract.py` 断言：用户可见品牌为“畅聊”、认证页具有稳定 Key、语义图标注册表包含六个关键图标、登录和注册页使用统一认证卡片。

- [x] **Step 2: 运行测试并确认因缺少新基座失败**

```powershell
python -m pytest tests/mobile/test_figma_ui_contract.py -q
```

Expected: FAIL，原因是 `changliao_icons.dart`、`AuthSurfaceCard` 和稳定 Key 尚不存在。

- [x] **Step 3: 写失败的 Flutter widget 契约**

更新 `auth_pages_test.dart` 和 `wechat_theme_test.dart`，要求登录/注册文案、字段、按钮、卡片、图标及 Light/Dark Token 与 Figma 一致。

### Task 3: 落实 Token 与语义图标注册表

- [x] **Step 1: 扩展语义 Token**

增加认证卡片圆角 12、输入框圆角 14、48px 控件高度、44px 最小触控尺寸、品牌/正文/辅助文字 Light/Dark 颜色和卡片阴影；保留现有 Token 名以兼容业务页面。

- [x] **Step 2: 建立语义图标注册表**

创建 `ChangliaoIcons`，稳定映射 `messages`、`contacts`、`discover`、`me`、`voiceCall`、`videoCall`、`microphone`、`camera`、`search`、`settings`、`wallet`、`gift` 到真实 Cupertino glyph。

- [x] **Step 3: 运行静态与主题测试**

```powershell
python -m pytest tests/mobile/test_figma_ui_contract.py tests/mobile/test_flutter_boundaries.py -q
```

Expected: PASS。

### Task 4: 重建登录与注册真实页面

- [x] **Step 1: 实现认证卡片和字段**

创建 `AuthSurfaceCard`、`AuthBrandMark` 和 `AuthTextField`，固定 24px 外边距、24px 内边距、白色浮层、12px 卡片圆角、48px 字段高度和 14px 字段圆角。

- [x] **Step 2: 将登录页映射到 Figma 节点 `28:2`**

保持现有 `LoginController`、提交回调、错误和加载状态；实现“畅聊”“使用用户名或邮箱登录”、用户名/邮箱、密码、端到端加密说明、登录和注册账号入口。

- [x] **Step 3: 将注册页映射到 Figma 节点 `29:370`**

保持现有 `RegistrationController` 和邀请码门禁；实现“创建畅聊账号”、用户名、邮箱、密码、邀请码、创建账号和返回登录入口。

- [x] **Step 4: 保持键盘与无障碍行为**

背景保持固定，表单通过滚动和底部 inset 避让键盘；按钮、字段和图标提供稳定 Key 与 Semantics。

- [x] **Step 5: 运行认证测试**

Flutter SDK 可用时运行：

```powershell
flutter test test/features/auth/auth_pages_test.dart test/ui/wechat_theme_test.dart
```

本机 Flutter 未加入 PATH 时使用 `C:\src\flutter\bin\flutter.bat` 执行同一命令。

### Task 5: 落实四栏主导航与用户可见品牌

- [x] **Step 1: 替换主导航硬编码图标**

`AppHome` 使用 `ChangliaoIcons.messages/contacts/discover/me`，保持现有四个真实业务 Tab 和通话 Overlay。

- [x] **Step 2: 更新用户可见品牌**

登录设备名、应用标题和认证页面统一为“畅聊”；`LiuhetongApp`、包名、Matrix ID 和技术资源名保持不变。

- [x] **Step 3: 运行设计契约和全仓验证**

```powershell
python -m pytest tests/mobile/test_figma_ui_contract.py tests/mobile/test_flutter_boundaries.py -q
pwsh -NoProfile -File scripts/verify.ps1
```

Expected: PASS。

### Task 6: 记录证据并提交首个生产纵向切片

- [x] **Step 1: 规格符合性审查**

逐项确认 Figma `10 Auth` 节点、Flutter 组件、测试断言、Light/Dark Token、真实图标、品牌边界和现有控制器接口一致。

- [x] **Step 2: 质量与安全审查**

确认未改变 Matrix/Business 信任边界，未引入网络图片、凭据、真实钱包地址、浮点资产逻辑或 E2EE 旁路。

- [x] **Step 3: 写验证证据并提交**

```powershell
git add -- apps/mobile_flutter tests/mobile docs/verification docs/superpowers/plans
git commit -m "feat(mobile): implement figma auth and navigation foundation"
git status --short
```

后续聊天、通话、通讯录、朋友圈、个人资料和金融页面分别按模块建立独立计划，复用本阶段 Token 与图标注册表，避免一次跨多个业务域的大爆炸式改动。
