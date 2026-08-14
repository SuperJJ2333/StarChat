# 登录网络故障修复验证（2026-08-14）

## 根因

1. Android 主清单缺少 `android.permission.INTERNET`。该权限此前只存在于
   debug/profile 清单，因此 Release APK 无法发起业务 API 或 Matrix 请求。
2. 本地业务库缺少与 Matrix 中 `@liuhetong_admin:matrix.localhost` 对应的
   `liuhetong_admin` 身份记录。
3. 登录签发 refresh token 时没有显式保证 token family 先于 token 刷入数据库；
   在启用外键约束的数据库中会触发外键错误。
4. Flutter 客户端没有把业务 API 的 HTTP 401 与网络异常区分开，导致错误提示不准确。

## 修复

- Release 主清单声明 `INTERNET`，并为本地 HTTP 联调启用 cleartext traffic。
- 本地默认端点改为配合 `adb reverse` 的 `127.0.0.1:8082` 与
  `127.0.0.1:8008`；雷电模拟器实测构建使用显式 `--dart-define` 指向宿主机联调桥。
- 同步业务身份与 Matrix 身份，并保持密码来自本地 `.env`，未写入仓库或日志。
- 在身份令牌签发流程中显式 flush device 与 refresh token family。
- 业务 API 401 显示“用户名或密码错误”，连接异常才显示网络重试提示。

## 验证证据

- Android 清单回归测试：通过。
- 身份令牌外键回归测试：通过（SQLite foreign keys 已显式启用）。
- Flutter 登录控制器测试：4 项通过。
- Flutter 全量测试：17 项通过；`flutter analyze` 无问题。
- Android Release APK 构建成功，包名为 `com.liuhetong.mobile`。
- `aapt2 dump permissions` 确认 APK 包含 `android.permission.INTERNET`。
- Docker 中 Business API、Worker、PostgreSQL、Redis 与 Synapse 均为 healthy。
- 宿主机直连 Business API 登录返回 HTTP 200；Matrix 登录返回 HTTP 200。
- 雷电模拟器 `emulator-5554` 安装签名 Release APK 后，使用
  `liuhetong_admin` 完成真实登录并进入“消息 / 通讯录 / 发现 / 我”主导航。

## 环境说明

雷电模拟器的 `adb reverse` 在当前版本上会登记映射但不实际转发流量；同时
Docker Desktop 的公开端口经该虚拟网卡会被重置。实测采用宿主机 HTTP 联调桥转发
业务 API，并通过构建期 `LIUHETONG_BUSINESS_API_URL` / 
`LIUHETONG_MATRIX_HOMESERVER` 注入当前宿主机地址。该环境差异不改变生产端点配置。
