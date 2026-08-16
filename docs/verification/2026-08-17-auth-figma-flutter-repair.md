# 畅聊认证页 Figma、Flutter 与雷电模拟器验证证据

日期：2026-08-17
分支：`feature/auth-figma-flutter-repair`
Figma：[`zpzwTbnj1hqx80tyRygX78`](https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78)

## 1. Figma 交付

- 在原页面 `10 Auth`（`18:6`）原位更新，没有新增认证页面；页面仍包含 24 个 393px 认证状态画板。
- 登录默认 Frame：`28:2`；注册默认 Frame：`29:370`；邮箱验证 Frame：`29:608`。
- 新增共享组件：
  - `Auth/BrandMark`：`81:2`
  - `Auth/Agreement` 组件集（Unchecked / Checked / Loading）：`81:18`
  - `Auth/InlineRegister`：`81:19`
- 24 个状态均使用新的 `landing.png`，Figma image hash 为 `16ee2e84b7bc7fec120b89600d8c78622f7f4890`，且每个状态仅包含一个 SVG Logo。
- 登录状态严格采用“安全说明 → 协议 → 登录按钮 → 轻量注册入口”的顺序式承诺；浅色默认、填写、加载、字段错误、服务异常，以及深色关键代表状态均已展开。
- Figma 不提供 Microsoft YaHei，画板使用 Noto Sans SC Regular / Medium 作为兼容字体；Flutter 继续按系统中文字体回退。
- 已截图复核登录未勾选、已勾选、注册、验证和深色状态：宽度均为 393px，主按钮固定 297px，无文本裁切。

## 2. 测试先行证据

### Red

- 静态 UI 合同首次运行因缺少 `AuthAgreementRow` 失败。
- Flutter 认证测试首次运行因 `LoginPage` 缺少协议回调失败。
- 新背景首屏位置测试预期卡片顶部不大于 160px，旧值为 260px，按预期失败。
- 模拟器视觉回归后补充测试：协议行旧高度为 176px、深色标题颜色为空，均按预期失败。
- 未勾选按钮弱化测试预期 `WeChatColors.textTertiary`，修改前实际图标为品牌绿色，按预期失败。

### Green

- `AuthBrandMark` 唯一通过 `SvgPicture.asset('assets/branding/liuhetong_logo.svg')` 渲染，并提供“畅聊 Logo”语义。
- `AuthAgreementRow` 为单行 44px 触控目标，协议链接分别可调用，加载时冻结。
- 登录按钮仅在协议已勾选且非加载状态可用；禁用状态图标和文字统一使用 `textTertiary`。
- `AuthInlineRegisterLink` 显示“还没有账号？立刻注册”，替代旧大号注册按钮。
- 注册页不增加协议门槛；邀请码、验证倒计时、重发和完成回调保持不变。

## 3. 自动化验证

| 命令 | 结果 |
|---|---|
| `dart format --output=none --set-exit-if-changed ...` | 7 个 Dart 文件，0 个需要修改 |
| `flutter analyze` | No issues found |
| `flutter test test/features/auth/auth_pages_test.dart` | 13/13 通过 |
| `flutter test` | 98/98 通过 |
| `python -m pytest tests/mobile/test_figma_ui_contract.py tests/mobile/test_flutter_boundaries.py -q` | 13/13 通过 |
| `pwsh -NoProfile -File scripts/verify.ps1` | PASS |

完整验证包含：Repository/Deployment policy、模板测试、配置渲染、Matrix Bot 9 项、Business API/Worker 161 项通过且 1 项跳过、Flutter boundary 16 项、导入、AST、迁移、OpenAPI drift 与 Docker Compose render，全部通过。

## 4. 雷电模拟器安装

- 在线设备：`emulator-5554`，型号 `ASUS_AI2501_A`。
- 宿主机联调地址：`192.168.1.116`；模拟器访问 Matrix `:8008/_matrix/client/versions` 和 Business API `:8082/openapi.json` 均返回 HTTP 200。
- 构建：`flutter build apk --debug --target-platform android-x64 --split-per-abi`，并显式注入 Matrix 与 Business API URL；产物为 `app-x86_64-debug.apk`。
- Release APK 与设备上保留数据的既有安装签名不兼容（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`）。为保留 Matrix 数据库和安全存储，改用同 Android Debug 证书构建并执行 `adb install --no-streaming -r`，结果 `Success`，未卸载或清空应用数据。
- 安装后：`com.liuhetong.mobile`，`versionName=0.1.0`，`versionCode=4001`；前台 Activity 为 `.MainActivity`；日志中 `FATAL EXCEPTION` 为 `NONE`。
- 运行截图：`apps/mobile_flutter/build/auth-repair-emulator-5554-final.png`。人工复核新背景、统一 SVG Logo、深色标题、单行协议、禁用登录按钮和文字注册入口均正确；页面可自然滚动。

## 5. 规范与安全边界审查

- 本次只调整认证展示层及本地未持久化协议状态，没有改变 Business/Matrix 双域认证、Token、E2EE、密钥恢复、RBAC、TOTP 或 API 合同。
- 未向服务端新增任何恢复密钥、明文消息、附件或通话媒体数据。
- 未触及账本、钱包、红包、资产精度、迁移和 OpenAPI。
- 未覆盖用户提供的 `landing.png` 与 `liuhetong_logo.svg`；旧 `launch_logo.svg` 已移除且源码不存在引用。
