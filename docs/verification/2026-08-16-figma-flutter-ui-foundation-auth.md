# 畅聊 Figma → Flutter 基础、认证与主导航验证证据

**日期：** 2026-08-16

**分支：** `feature/changliao-html-figma`

**Figma：** [畅聊 HTML → Figma 移动端设计系统](https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78)

## Figma 来源与页面归一化

- 已删除重复的 `09 登录与注册` 页面（原节点 `52:2`）。
- 原有 `10 Auth`（节点 `18:6`）保留为认证唯一来源，包含 24 个登录、注册、验证和异常状态。
- Flutter 登录映射 `auth-login-default`（节点 `28:2`）。
- Flutter 注册映射 `auth-registration-default`（节点 `29:370`）。
- 主导航参考 `messages-inbox-default`（节点 `30:2`）和 `05 Icons 图标库` 的真实组件。

## 测试先行证据

首次运行：

```powershell
python -m pytest tests/mobile/test_figma_ui_contract.py -q
```

结果：4 项失败，失败原因分别为 Flutter 仍含用户可见“六合通”、语义图标注册表不存在、统一认证卡片不存在、393×852 几何 Token 不存在。

主导航使用契约单独执行红灯：

```powershell
python -m pytest tests/mobile/test_figma_ui_contract.py::test_app_shell_consumes_semantic_navigation_icons -q
```

结果：1 项失败，原因是 `AppHome` 尚未使用 `ChangliaoIcons`。

## 实现结果

- 新增 `ChangliaoIcons` 语义图标注册表，消息、通讯录、发现、我、语音、视频、麦克风、相机、搜索、设置、钱包、红包等均为真实 Cupertino glyph。
- 新增 `AuthSurfaceCard`、`AuthBrandMark`、`AuthTextField`，落实 345px 最大卡片宽度、24px 内边距、12px 卡片圆角、14px 输入框圆角和 48px 控件高度。
- 登录页保留原 `LoginController`、Business/Matrix 双域登录、错误、重试、加载和键盘避让逻辑。
- 注册页保留原 `RegistrationController`、邀请码门禁、字段错误、加载、验证跳转和返回登录逻辑。
- `AppHome` 四栏主导航改用语义图标注册表，现有真实业务 Tab 和来电 Overlay 不变。
- Android 显示名、iOS Display Name、Flutter title、设备显示名及用户可见“畅聊号”“畅聊朋友圈”“畅聊彩币红包”完成同步；`LiuhetongApp`、`liuhetong_mobile`、Matrix ID 和技术资源名保持不变。

## 自动化验证

```powershell
python -m pytest tests/mobile/test_figma_ui_contract.py tests/mobile/test_flutter_boundaries.py -q
```

- 11/11 通过。

```powershell
& 'C:\src\flutter\bin\flutter.bat' analyze
```

- `No issues found`。

```powershell
& 'C:\src\flutter\bin\flutter.bat' test
```

- 83/83 通过。

```powershell
npm --prefix design-demo run verify
```

- 13/13 Demo 契约测试通过，Browser smoke PASS，326/326 截图生成成功。

```powershell
pwsh -NoProfile -File scripts/verify.ps1
```

- 退出码 0；Repository、Deployment、Template、Render、Migrations、OpenAPI、Docker 全部通过。
- Matrix Bot 9 项、Business API/Worker 161 项（1 项跳过）、Flutter 边界 14 项通过。

## 视觉复核

- 使用 393×852、1.0 DPR 的临时 Flutter Golden 捕获登录和注册页面。
- 登录卡片在 Safe Area 后保持 Figma 的 260px 内容上边距；注册卡片保持 180px 上边距并支持自然滚动。
- 背景使用仓库内 `assets/landing.png`，没有运行期远程图片依赖。
- 临时 Golden 测试和图片在人工检查后清理，未进入交付物。

## 边界审查

- 未修改 Business API、Matrix 会话协议、E2EE、账本、红包分配、钱包状态机、迁移或 OpenAPI。
- 未引入外部图标库、运行时网络资产、密钥、Token、真实钱包地址或敏感日志。
- 认证提交仍调用原控制器和网关；本次仅改变展示组件和用户可见品牌。
