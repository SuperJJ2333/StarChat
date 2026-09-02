# 登录状态保持（60 天同设备缓存）— 根因与验证证据（2026-08-30）

需求：①为什么每次更新都要重新登录；②为什么退出 App 约两小时后要重新登录；③同一设备保存 60 天登录缓存。决策记录：`docs/adr/0009-sixty-day-device-login-cache.md`。

## 根因（生产数据实锤）

会话令牌一直持久化在 flutter_secure_storage（更新安装不丢失），问题不在存储，而在**刷新竞态**：

1. 服务端安全机制：refresh token **单次使用**，重放已消费令牌 → `rotate()` 判定 `TOKEN_REUSE` 并**撤销整个设备令牌族**（所有会话失效，必须重登）。
2. 客户端缺陷：`BusinessApiClient._authorized` 对每个 401 响应**各自**调用 `refreshSession()`，无 single-flight 锁。业务 access token 有效期 15 分钟；首页聚合加载（余额/资料/更新检查等多个并发请求）在令牌过期后同时收到 401，同时用**同一个** refresh token 换新——第一个成功，其余命中重用检测 → 设备令牌族被撤 → 踢回登录页。
3. 生产证据：`refresh_token_families` 共 73 族，其中 **14 族（19%）`revoke_reason=TOKEN_REUSE`**（另 LOGOUT 12、PASSWORD_RESET 4）——全部是竞态误伤而非真实攻击。
4. 两个现象同源：「退出两小时后要重登」实际阈值是「离开超过 15 分钟（access 过期）后回来触发并发 401」；「每次更新都要重登」是更新冷启动前令牌族已被竞态撤销。

## 修复（不弱化安全）

| 端 | 改动 | 安全边界 |
| --- | --- | --- |
| 服务端 `tokens.py` | refresh 生命周期 30 天 → **60 天**（rotate 滑动续期：每次刷新新记录 `expires_at=now+60d`） | 单次使用、TOKEN_REUSE 撤族、设备绑定、登出/改密撤族、access 15 分钟全部保留 |
| 客户端 `business_api_client.dart` | `refreshSession()` 增加 **single-flight**：并发 401 共享同一次网络刷新，完成后以新 access token 各自重放；顺带修复刷新后 `deviceKey` 丢失 | 刷新失败语义不变（401/403 清会话、网络错误按离线） |

语义：同一设备 60 天内至少活跃一次即持续在线（每次活跃自动续 60 天）；连续 60 天不活跃才需要重新登录。手动退出登录、改密、管理端吊销设备仍立即失效。

## 测试（先红后绿）

- 服务端新增 `test_refresh_rotation_slides_sixty_day_expiry`：红（30 天 ≠ 60 天）→ 绿；identity 套件 **80 passed**。
- 客户端新增 `concurrent 401s share a single refresh flight`：红（refresh 网络调用 2 次，精确复现撤族竞态）→ 绿（1 次）；全量 `flutter test` **408 passed**。
- 服务端业务套件 `pytest tests/business_api tests/business_worker`：**237 passed, 1 skipped**。

## 发布

- **服务端**（已生效）：`tokens.py` 同步至 `/opt/starchat/{services/business-api,backend}` → 重建镜像 → `starchat-business-api-1` 重启；`/api/v1/health/ready` OK；容器内introspect 部署代码确认默认 `refresh_lifetime = 60 days`。
- **客户端 0.3.7+10**（已发布）：`pubspec.yaml` 版本升级；Release 分 ABI 签名构建（arm64 SHA256 `7CEEBCC6F4965C30C8AC5CF3040E017F64D2B4351AFEB5AAA63A2047014A50A2`）；三 APK 上传 `/opt/starchat/frontend/downloads/` 且服务端哈希逐一比对一致；落地页链接指向 `ChatFlow-0.3.7-arm64.apk`；更新设置发布 `latest_version=0.3.7 / latest_build=10 / min_supported_build=3`（幂等键 `app-update-publish-0.3.7-20260830`），未认证端点 `/api/v1/app-updates/latest` 确认下发。
- **外部验证**：`verify_public_domains.ps1` 全项 PASS（DNS、HTTPS、落地页内容、三 APK 下载 200、业务 API 健康、Matrix 发现）。

## 用户沟通口径

1. **为什么每次更新都要重新登录**：不是更新清了数据，而是更新前的使用中登录凭据已被「并发刷新竞态」误伤作废，更新冷启动即失效。已修复。
2. **为什么两小时后要重新登录**：离开超过 15 分钟（访问令牌过期）后回来，多个请求并发刷新互相触发安全检测把会话作废。「两小时」是离开时长，阈值实为 15 分钟。已修复。
3. **60 天缓存**：已实现——同一设备 60 天内活跃即自动续期不掉线；连续 60 天不打开 App 才需重登。手动退出、改密、设备吊销仍立即失效。
