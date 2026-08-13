# 微信风格移动端完整回归

日期：2026-08-14

## 自动验证

- `scripts/verify.ps1`：PASS；Matrix Bot 8 项、Business API/Worker 76 项（1 跳过）、Flutter 边界 2 项、AST、单 Alembic head、OpenAPI 和 Compose 渲染全部通过。
- Flutter `analyze`：无问题；Flutter tests：16 项通过。
- Docker：Business API、Worker、两个 PostgreSQL、Redis、Synapse 均启动；API/Synapse 宿主端口为 8082/8008。
- 迁移：生产型 PostgreSQL 已升级至 `0014_moments_prefs`；后续 `0015_contact_tags` 由下一次镜像部署自动执行。

## 构建与设备

- 签名 Release APK：`build/app/outputs/flutter-apk/app-release.apk`，55.6 MB。
- 签名 Release AAB：`build/app/outputs/bundle/release/app-release.aab`，52.9 MB。
- 两台雷电模拟器 `emulator-5554`、`emulator-5556` 安装成功；8082/8008 均配置 `adb reverse`。
- UIAutomator 确认包名 `com.liuhetong.mobile`，登录页可见“六合通”、账号密码框和登录按钮。
- 宿主健康检查：`http://127.0.0.1:8082/api/v1/health/live` 返回 `ok=true`。

## 规格与安全复核

- 四 Tab、微信色板、通讯录、好友请求/备注/标签/拉黑/朋友圈权限、朋友圈五种可见范围和四种时间范围已落地。
- Matrix 文本和附件只经 Matrix SDK；加密房间由 SDK 对事件及附件加密，业务 API 不接触明文或密钥。
- 彩币/红包/USDT 仍以业务 API 和不可变账本为权威；Matrix 卡片不更新余额。
- 朋友圈是独立非 E2EE 社交域，所有读取复用可见性策略；举报、审核状态、搜索和推荐开关可由服务端处理。

## 环境边界

- 本地认证策略未启用验证码，因此验证码输入/错误验证码场景不适用。
- iOS TestFlight 构建仍由已配置的 GitHub Actions macOS 工作流在 Apple 凭证注入后执行；Windows 不能生成真机签名 iOS 包。
- 托管钱包当前为版本固定的 Sandbox provider；真实 TRC20 托管上线需注入供应商凭证并执行同一契约测试。