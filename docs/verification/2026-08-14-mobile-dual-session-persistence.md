# 双域持久会话修复验证记录

**日期：** 2026-08-14  
**分支：** `feature/mobile-dual-session`  
**规格：** `docs/superpowers/specs/2026-08-14-mobile-dual-session-persistence-design.md`

## 1. TDD 证据

| 行为 | RED | GREEN |
|---|---|---|
| 停用账号不得刷新 | 新增用例时 `rotate()` 仍签发令牌 | `5 passed` |
| Business 令牌对原子存储、迁移 | 新 API 不存在导致编译失败 | 存储聚焦测试通过 |
| Refresh、一次重放、注销 | 新会话 API 不存在导致编译失败 | Business 会话测试通过 |
| SQLCipher Matrix Client | 工厂 API 不存在导致编译失败 | Matrix 工厂测试通过 |
| 双域启动状态机 | 控制器类型不存在导致编译失败 | 启动状态测试通过 |
| 启动路由与主动注销 | 登录页仍被无条件渲染 | Widget 测试通过 |
| 注销销毁 Matrix 本地材料 | `resetClient`、`reset()` 不存在导致编译失败 | 3 个 Matrix 重置测试通过 |
| Android 原生 E2EE 库 | 边界测试缺少 `flutter_olm`；模拟器报告 `libolm.so not found` | APK 同时包含 x86_64/arm64-v8a/armeabi-v7a 的 `libolm.so`、`libcrypto.so`，两模拟器启动不再报告动态库错误 |

## 2. 自动验证

- `flutter analyze`：通过，`No issues found`。
- `flutter test`：通过，`41 tests passed`。
- `py -3.12 -m pytest tests/business_api/identity/test_tokens_and_recovery.py -q`：`5 passed`。
- `py -3.12 -m pytest tests/mobile/test_flutter_boundaries.py -q`：`3 passed`。
- `pwsh -NoProfile -File scripts/verify.ps1`：通过；Business API/Worker `79 passed, 1 skipped`，Matrix Bot `8 passed`，迁移、OpenAPI、Compose 渲染均通过。
- `flutter build apk --release`：通过，生成已签名 `app-release.apk`。
- APK 权限：包含 `android.permission.INTERNET`。

首次执行仓库验证时，隔离 worktree 缺少被 Git 忽略的本地 `.env`，配置渲染按预期拒绝运行；复制主工作区的本地 `.env` 后完整验证通过，文件未加入 Git。

## 3. 双模拟器验收

设备：`emulator-5554`、`emulator-5556`。

1. 两台设备安装同一签名 Release APK，清除旧数据后分别登录测试账号。
2. 首次登录均进入四 Tab 主页，日志无 `ClientException`、`MatrixException`、未处理异常或崩溃。
3. Matrix 本轮设备 ID 分别为 `WZQUJZIQQB`、`VKOPWWXVWG`。
4. 强制停止并重启两台 APP，均直接进入主页，不显示登录页；服务端设备行未增加，设备 ID 保持不变。
5. 账号 01 搜索账号 02 并提交好友申请，API 返回 `201`；账号 02 接受，API 返回 `200`。
6. 再次重启刷新通讯录后，账号 01 显示账号 02，账号 02 显示账号 01。
7. 更新包含原生 E2EE 库的 APK 后再次原位安装，两个持久会话仍直接恢复，Matrix 加密初始化未报告 `libolm`/`libcrypto` 错误。

## 4. 规格符合性（Domain Review）

- **通过：** Business 与 Matrix 仍通过各自公开接口协调；没有跨域直写数据表。
- **通过：** Business 令牌对使用单条版本化安全记录；不保存用户名或密码。
- **通过：** Refresh Token 明确失效、账号非 `ACTIVE`、Matrix Token 明确失效才退出；网络异常保留离线会话。
- **通过：** Business/Matrix 稳定身份不一致时 fail closed，不自动拼接会话。
- **通过：** 主动注销依次尽力撤销 Business、注销 Matrix、清理令牌、关闭并删除 Matrix 数据库、轮换 SQLCipher 密钥。
- **通过：** 未改变账本、钱包、红包、审批、RBAC 或 OpenAPI 契约。

## 5. Quality/Security Review

- **SQLCipher：通过。** `emulator-5554` 数据库头为随机字节 `3c 27 de 67 ...`，不是 `SQLite format 3`。
- **原生 E2EE：通过。** APK 包含三种 Android ABI 的 `libolm.so` 与 `libcrypto.so`；两台模拟器均成功初始化 Matrix 加密模块。
- **安全存储：通过。** Business Token 与数据库密钥仅通过 `FlutterSecureStorage` 持久化；恢复密钥键保持独立。
- **退出清除：通过。** 聚焦测试证明旧 Client 被注销、关闭，旧数据库被删除，SQLCipher 密钥被轮换，并返回可复用的空 Client。
- **日志：通过。** 验收日志未记录密码、Token、SQLCipher 密钥、恢复密钥或消息正文。
- **E2EE 边界：通过。** 消息、附件、房间密钥和恢复密钥没有流入 Business API；补充原生库只恢复 Matrix SDK 既定加密能力。

## 6. 结论

双域持久会话规格的自动化与双模拟器验收项全部通过。用户关闭、强制停止或更新 APP 后保持同一 Business 会话和 Matrix 设备；仅主动退出或权威失效才返回登录页。
