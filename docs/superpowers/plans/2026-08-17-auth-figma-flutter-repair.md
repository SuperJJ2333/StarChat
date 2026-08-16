# 畅聊认证页 Figma 与 Flutter 修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 使原 Figma `10 Auth`、Flutter 认证页和雷电模拟器统一使用新背景、指定 SVG Logo、登录协议勾选与文字注册入口。

**Architecture:** 保留现有认证控制器和双域登录数据流，只修改认证展示层。共享组件集中管理 Logo、协议行和注册链接；登录页本地持有协议状态，注册与验证页仅复用品牌组件。Figma 原页面按同一组件槽位展开状态，不创建新页面。

**Tech Stack:** Figma Plugin API、Flutter 3.44、Cupertino、flutter_svg、flutter_test、PowerShell 7、ADB。

---

### Task 1: 审计 Figma 与本地认证资产

**Files:**
- Read: `apps/mobile_flutter/assets/landing.png`
- Read: `apps/mobile_flutter/assets/branding/liuhetong_logo.svg`
- Read: `apps/mobile_flutter/lib/features/auth/login_page.dart`
- Read: `apps/mobile_flutter/lib/features/auth/registration_page.dart`
- Read: `apps/mobile_flutter/lib/features/auth/verification_page.dart`

- [x] 使用 `get_metadata` 定位原 `10 Auth` 页面和现有状态 Frame。
- [x] 使用 `get_design_context` 获取登录默认 Frame 的设计上下文。
- [x] 检查新背景、SVG Logo、现有 Flutter DOM/Widget 嵌套与 Token。
- [x] 记录用户资产修改，禁止覆盖或重新生成这两个资产。

### Task 2: 以失败测试锁定共享品牌和登录协议行为

**Files:**
- Modify: `apps/mobile_flutter/test/features/auth/auth_pages_test.dart`
- Modify: `tests/mobile/test_figma_ui_contract.py`

- [x] 添加测试：三个认证页均包含由 `SvgPicture` 渲染的 `assets/branding/liuhetong_logo.svg`。
- [x] 添加测试：登录初始未勾选且按钮禁用。
- [x] 添加测试：勾选协议后登录按钮可用并能提交。
- [x] 添加测试：协议链接分别触发回调，加载时不可交互。
- [x] 添加测试：显示“还没有账号？立刻注册”，且仅文字入口调用 `onRegister`。
- [x] 添加测试：注册页没有协议勾选，邀请码仍独立控制提交。
- [x] 运行聚焦测试并确认因缺失组件和行为按预期失败。

### Task 3: 实现共享认证组件与登录顺序式承诺

**Files:**
- Modify: `apps/mobile_flutter/lib/ui/components/auth_surface_card.dart`
- Modify: `apps/mobile_flutter/lib/features/auth/login_page.dart`
- Modify: `apps/mobile_flutter/lib/ui/foundation/wechat_tokens.dart`（仅在现有 Token 无法表达 44px 触控目标时）

- [x] 将 `AuthBrandMark` 改为唯一使用 `SvgPicture.asset('assets/branding/liuhetong_logo.svg')`，保持原始比例和“畅聊 Logo”语义。
- [x] 新增 `AuthAgreementRow`，固定 44px 触控目标、checked/enabled 语义、两项协议回调与加载禁用状态。
- [x] 新增 `AuthInlineRegisterLink`，固定提示文案和品牌绿色注册动作。
- [x] 在 `LoginPage` 增加未持久化的 `_agreementAccepted`，严格按 Logo、标题、字段、安全说明、协议、登录、注册入口顺序组合。
- [x] 未勾选或加载时禁用登录；移除旧“注册账号”大按钮。
- [x] 运行认证聚焦测试并确认全部转绿。

### Task 4: 统一注册与验证页品牌结构

**Files:**
- Modify: `apps/mobile_flutter/lib/features/auth/registration_page.dart`
- Modify: `apps/mobile_flutter/lib/features/auth/verification_page.dart`
- Test: `apps/mobile_flutter/test/features/auth/auth_pages_test.dart`

- [x] 确认注册和验证页只通过 `AuthBrandMark` 使用 SVG Logo。
- [x] 保持注册邀请码、字段错误、验证倒计时、重发和完成回调不变。
- [x] 调整间距以适配 393×852，键盘弹出时内容自然滚动。
- [x] 运行全部认证测试并确认通过。

### Task 5: 更新原 Figma `10 Auth`

**Figma:**
- File: `zpzwTbnj1hqx80tyRygX78`
- Page: `10 Auth`

- [x] 复用现有 Token 和组件，在原页面内更新共享 Logo、背景、协议行与文字注册入口。
- [x] 展开浅色登录未勾选、已勾选、加载、字段错误、服务异常状态。
- [x] 更新浅色注册默认、填写、加载、字段错误状态。
- [x] 更新浅色邮箱验证默认、倒计时、成功、失败状态。
- [x] 更新深色登录已勾选关键代表状态。
- [x] 使用 `get_screenshot` 检查 393px 宽度、文字无裁切、状态与 Flutter 一致。

### Task 6: 完整验证与证据

**Files:**
- Create: `docs/verification/2026-08-17-auth-figma-flutter-repair.md`
- Modify: `docs/superpowers/plans/2026-08-17-auth-figma-flutter-repair.md`

- [x] 运行 `dart format` 检查修改文件。
- [x] 运行 `flutter analyze`。
- [x] 运行 `flutter test`。
- [x] 运行 `python -m pytest tests/mobile/test_figma_ui_contract.py tests/mobile/test_flutter_boundaries.py -q`。
- [x] 运行 `pwsh -NoProfile -File scripts/verify.ps1`。
- [x] 记录 Figma 节点、Red/Green、测试数量、规范符合性和安全边界审查。
- [x] 将计划所有步骤标记为完成并提交代码与证据。

### Task 7: 构建并安装到雷电模拟器

**Artifacts:**
- Build: `apps/mobile_flutter/build/app/outputs/flutter-apk/app-x86_64-debug.apk`
- Device: `emulator-5554`

- [x] 从雷电实例验证宿主机可访问地址，注入 Matrix 和 Business API URL。
- [x] 先构建 `android-x64` 分架构 Release APK；若与保留数据的已安装签名不兼容，则构建同证书 Debug APK 覆盖安装。
- [x] 使用 `adb install --no-streaming -r` 覆盖安装。
- [x] 启动 `com.liuhetong.mobile/.MainActivity`。
- [x] 检查前台 Activity、进程和 `FATAL EXCEPTION`。
- [x] 截图确认登录页显示新背景、统一 Logo、协议勾选和文字注册入口。
- [x] 将安装证据补充到验证文档。
