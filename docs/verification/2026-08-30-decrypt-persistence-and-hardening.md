# 解密持久性修复 / 未解密会话隐藏 / 发布 0.3.3 — 验证证据（2026-08-30）

## 1. 根因定位：两条"清库"路径导致历史密钥丢失

生产症状「同设备同账号，退出账号或更新 APP 后全部会话显示"消息尚未解密"」的根因是本地加密数据库（SQLCipher，存 Olm 账号与 Megolm 入站会话）被两条代码路径整体删除：

1. **启动自举路径**（`session_bootstrap_controller.dart`）：业务会话恢复失败（`absent/invalid`——登出会吊销业务 refresh_token；升级窗口期令牌过期后任何瞬时刷新失败同理）→ 调用 `_bestEffortMatrixReset()` → **删除整个本地加密库**。下次登录时本设备 Megolm 会话已不存在，全部历史消息无法解密。
2. **登录清理路径**（`login_controller.dart`）：登录过程中**任何**异常（含 SocketException/超时等网络类失败）→ `_cleanupMatrix()` → `matrix.logout()` + 重置本地库 → 同样清库。

**修复**：
- 启动自举：业务会话失效只回登录页，**不再清除本地加密库**。账号隔离边界移至登录流程的身份校验（`matrix.userId != grant.matrixUserId` 时才 `resetLocalStore`）——换账号登录仍会重置，安全边界不变。
- 登录清理：删除 `_cleanupMatrix` 的清库行为；网络类失败保留本地库与会话，重试即可。
- 密钥与库生存周期核验：SQLCipher 密钥为安装级随机值存于 flutter_secure_storage（升级/重启稳定）；`MatrixClientFactory.reopen` 保留库与 Olm 会话；`reset`（清库）仅剩"不同账号登录"一条触发路径。

## 2. 消息页隐藏未解密会话（可逆、不删数据）

- 消息页会话列表过滤：`room.lastEvent?.type == Encrypted`（最后一条消息尚未解密）的会话**不显示**。同步后密钥就绪、消息可解密时会话自动重新出现；数据从不删除。`conversation_presentation` 的"消息尚未解密"文案保留用于房间内展示兜底。

## 3. 发布 0.3.3（versionCode 6）

- `ChatFlow-0.3.3-arm64/arm32/x86_64.apk` 已上传下载页（arm64 SHA256 见构建输出），0.3.2 包下线；落地页 `releaseVersion` 同步 0.3.3；域名验证 PASS（落地页内容 + APK HEAD 200）。
- 更新推送：`PUT /admin/app-update-settings` 发布 `latest=0.3.3/build 6, min_supported=3`，notes 与 apk_url 指向 0.3.3（幂等键 `app-update-publish-0.3.3-20260830`）；公开端点 `GET /app-updates/latest` 确认 configured:true。
- 模拟器烟测：x86_64 包装机成功（versionName=0.3.3）。
- 行为矩阵：build 6 不弹窗；build 4–5（0.3.1/0.3.2）弹可忽略更新；build ≤3 强制更新。

## 4. 验证

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found |
| `flutter test` | **384 passed**（bootstrap 契约反转：业务失效不再清库；登录失败不清库） |
| `pytest tests/business_api/friendship` | 14 passed |
| `verify_public_domains` | PASS（落地页内容 + 0.3.3 APK HEAD 200） |
| 模拟器 | 0.3.3 安装启动正常（versionName=0.3.3） |

## 5. 遗留事项（非阻塞）

- 已被旧版本清过库的设备：历史密钥不可恢复（端到端加密语义决定）；新版本起密钥持久性得到保障。后续可评估服务端 Megolm 密钥备份（SSSS + recovery key 恢复流程，客户端接口已具备 `backupKeysToEncryptedStore`/`restoreEncryptedBackup`）以进一步兜底。
- 账号隔离路径（不同账号登录重置本地库）保留并有测试覆盖（`mismatched domain identities fail closed without deleting data` 及登录身份校验）。
