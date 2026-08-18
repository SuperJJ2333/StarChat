# 2026-08-18 畅聊生产数据迁移验证证据

## 结论

- ADR `0005-production-cutover-preserve-matrix-identity` 已为 `Accepted`。
- 生产目标 `liuhetong-prod`（`207.56.8.8:23421`）已承载 Business、Matrix、媒体、Bot store、HTTPS 网关与 TURN；三个公网域名均指向该目标。
- 本机写入服务继续保持停止，禁止形成双写或回滚源被污染。
- Business/Matrix 公网健康、Business 登录、Business → Matrix 60 秒单次登录令牌链路、历史核心计数、Matrix signing key 与媒体哈希均已验证。
- 两个测试账号的 Business、Matrix、双模拟器会话恢复和新 E2EE 消息回归已经通过。当前遗留门禁为目标网络阻断出站 UDP/123、QQ SMTP 尚缺少对应邮箱账号，以及新设备没有历史房间密钥而无法解密部分旧 E2EE 消息。详见“未关闭门禁”。

## 时间线

| 事件 | UTC | Asia/Hong_Kong |
| --- | --- | --- |
| 停止本机写入者 | 2026-08-18 06:48:07 | 2026-08-18 14:48:07 +08:00 |
| 生产公网稳定验收 | 2026-08-18 08:20 左右 | 2026-08-18 16:20 左右 +08:00 |
| 证据收口 | 2026-08-18 08:27 左右 | 2026-08-18 16:27 左右 +08:00 |

停机窗口超过原估算，主要耗时为目标首次安装 Docker/依赖、拉取固定镜像和构建三个 Python 服务。

## 源端清单与静止证明

实际 mount 以 `docker inspect` 为准，而非以当前工作目录推断：

- Synapse PostgreSQL：旧工作树 `data/postgres` → `/var/lib/postgresql/data`。
- Synapse data/signing/media：旧工作树 `data/synapse` → `/data`。
- Business PostgreSQL：仓库根 `data/business-postgres`。
- Business API media：仓库根 `data/business-media`。
- Business Worker media：旧工作树 `data/business-media`；与 API media 归档后安全合并，无路径冲突。
- Matrix Bot store：旧工作树 `data/bot`。
- Redis 不迁移，只在目标创建空实例。

停机后两个 PostgreSQL 的业务活动连接均为 0。以下本机容器在证据收口时仍为 `exited`：

- `starchat-business-worker-1`
- `starchat-business-api-1`
- `starchat-matrix-bot-1`
- `starchat-synapse-1`
- `starchat-element-web-1`
- `starchat-coturn-1`

## 一致性导出与传输

- Synapse：PostgreSQL 16.9 custom-format dump，源逻辑大小约 18 MB。
- Business：PostgreSQL 16.9 custom-format dump，源逻辑大小约 9.3 MB。
- 迁移包包含 Synapse signing/config/media、Bot store、两个 Business media 源及受控 Git archive。
- `pg_restore -l` 已分别验证两个 dump 可读。
- 14 个传输文件在目标执行 `sha256sum -c SHA256SUMS`，全部通过。
- 本地迁移目录受当前 Windows 用户 ACL 限制；目标 `/opt/starchat-migration` 为 root-only，文件权限为 `0600`。
- `.env`、dump、媒体、私钥和 Token 均由 `.gitignore` 排除且未写入文档或命令输出。

源端关键计数：

| 域 | 计数 |
| --- | --- |
| Business users | 3 |
| Business friendships | 1 |
| Business identity_devices | 7 |
| Business audit_events | 14 |
| Business outbox_events | 7 |
| Synapse users | 4 |
| Synapse rooms | 9 |
| Synapse events | 281 |
| Synapse room_memberships | 20 |
| Synapse state_groups | 101 |

账本源端检查：CAIBI/USDT 非零差额资产数和不平衡交易数全部为 0；源端所有账本交易/分录、红包、充值和提现表当前也均为 0。迁移过程未从 Matrix、通知或客户端状态派生或修改任何金融数据。

## 目标恢复与密码学连续性

- 保持 `server_name: matrix.localhost`，未更改 Matrix ID、房间 ID、MXC URI 或 E2EE 边界。
- 源/目标 signing key SHA-256 完全一致。
- Synapse media 13 个文件逐文件相对路径和 SHA-256 完全一致。
- Business media 1 个文件逐文件相对路径和 SHA-256 完全一致。
- Bot store 在启动前由传输 manifest 验证；启动后 sync token/本地数据库发生预期运行时更新，不再要求字节级相等。
- Business 最终核心计数仍为 users=3、friendships=1、outbox_events=7，账本/钱包/红包计数仍为 0。验收登录产生了预期的 audit_events=23、identity_devices=11。
- Synapse 最终 rooms=9、events=281、room_memberships=20、state_groups=101 均与源一致。验收登录产生额外 access token/device。
- 源数据缺少 Business 已引用的 `@liuhetong_admin:matrix.localhost`；通过受保护的 Synapse Admin API 补齐该身份，未直接写 Synapse 表。故目标 Synapse users=5。补齐后 Business → Matrix 单次登录令牌真实链路通过。

## Domain review

- Business PostgreSQL 是身份、好友、审计、Outbox、账本、红包和钱包的唯一迁移来源。
- Synapse PostgreSQL/data 是 Matrix 用户、房间、事件、设备、signing key 和媒体的唯一迁移来源。
- 未从 Matrix 消息、Bot 回调、通知或 UI 状态写入 Business 或金融表。
- 两个 Business media 源先独立归档，再在目标同一目录合并；唯一实际文件无冲突且哈希一致。
- Redis 明确不迁移；目标从空实例启动。
- 邮件供应商尚未配置时使用显式 `SMTP_DELIVERY_ENABLED=false` fail-closed 模式：邮件任务明确失败且不泄露内容，红包到期、钱包维护和朋友圈审核等非邮件维护任务继续运行。新注册/找回邮件尚不具备生产交付能力。

## Quality / Security review

- 迁移秘密未进入 Git、验证文档或非敏感日志；生产 `.env` 权限为 `0600`。
- 目标重新生成 TURN、Business JWT/验证/重置/头像签名/钱包 webhook 等生产秘密；内部 PostgreSQL 密码已轮换，数据库端口未暴露公网。
- Matrix signing key 保持原值并以 SHA-256 比对；未向服务端提供恢复密钥、房间密钥、消息明文或解密媒体。
- Nginx 使用固定 `nginx:1.27.5-alpine`，Docker DNS 动态解析上游容器；API/Synapse/Element/Bot 仅绑定 loopback 或容器网络。
- 公网端口探测确认 5432、6379、8008、8081、8082 均阻断；仅 80、443、23421 及批准 TURN 端口开放。
- Synapse Admin 路由在主域和管理域均返回 404。
- TLS 证书覆盖三个域名，有效期至 2026-11-16；Certbot timer 和证书复制/Nginx reload deploy hook 已启用。
- 源端写入者继续停止并保留完整数据，作为只读回滚基线；目标已接受公网写入后不得无损假设回滚，必须先处理目标增量。

## 公网、服务与客户端证据

- `scripts/verify_public_domains.ps1`：全部 PASS。
- Business live/ready：200。
- Matrix `/_matrix/client/versions`：200。
- Matrix `.well-known`：`https://liuhetong888.com/`。
- `www` HTTP/HTTPS 均保持 path/query 301 到主域。
- 管理域仅开放 Business API，根路径和 Synapse Admin 均为 404。
- 生产容器：两个 PostgreSQL、Redis、Synapse、Business API、Business Worker、Matrix Bot、Element、TURN、Mailpit、Gateway 均运行；有 healthcheck 的服务全部 healthy。
- 真实 Business 管理账号登录通过；随后 Business → Matrix 60 秒登录令牌 → `m.login.token` 登录通过。
- 域名 Debug APK 已以 `adb install -r` 安装并启动到 `emulator-5554`、`emulator-5556`；SHA-256 为 `7FAA3E5129154AC05F6A240AD6BE92BC6CE87B789C4CB20D2E950D0055F0DEBB`。
- 用户授权后，两个测试账号通过公开 password-forgot/password-reset 应用流程更新运行时密码；产生 2 条成功审计记录和 2 个预期的 24 小时 `PASSWORD_RESET` 提现安全 hold，未直接修改用户表。
- `liuhetong_test01`、`liuhetong_test02` 的 Business 登录、60 秒 Matrix 登录令牌和 `m.login.token` 登录全部通过。
- 两台模拟器分别登录两个测试账号，force-stop 后重新启动仍直接进入消息首页。
- 从 `emulator-5554` 发送新的 E2EE 验收消息，`emulator-5556` 的会话列表和聊天页均显示已解密明文，未出现 session key 缺失错误。

## 自动化验证

`pwsh -NoProfile -File scripts/verify.ps1`：PASS。

- Repository policy：PASS
- Deployment policy：PASS
- Matrix Bot：9 passed
- Business API/Worker：163 passed, 1 skipped
- Flutter boundaries：19 passed
- Business import、AST、Alembic、OpenAPI、Compose render：PASS

## 未关闭门禁

1. **NTP 状态**：目标网络对 Ubuntu、Cloudflare、Google、Windows NTP 的 UDP/123 均超时，`NTP=yes` 但 `NTPSynchronized=no`。使用三个独立受信 HTTPS Date 响应形成共识后，一次性把约 `+13.478s` 偏差校正为 `0.000s`；失败的定时 HTTPS workaround 已完全删除。仍需云厂商开放出站 UDP/123，之后确认 `NTPSynchronized=yes`。
2. **邮件交付**：已收到 QQ SMTP 授权码，但 QQ SMTP 还必须提供与授权码绑定的完整邮箱账号，才能设置 `SMTP_USERNAME`、发件人并执行真实投递。Worker 目前仍以显式 fail-closed 邮件模式健康运行；现有账号和非邮件维护任务可用，新注册、验证邮件和密码找回邮件暂不可交付。
3. **历史 E2EE 密钥**：两个新登录设备可收发并解密新 E2EE 消息，但部分旧会话显示缺少 session key。服务端按 E2EE 边界没有房间密钥，迁移包也不包含客户端恢复密钥；必须从仍持有旧密钥的设备执行 Matrix cross-signing/secret-storage 恢复，或提供用户自己的恢复密钥后才能关闭历史消息解密门禁。

## 当前权威性与回滚

- 公网域名当前指向目标且目标已经可以接受写入，因此生产目标是当前 authoritative 实例。
- 本机源仍保持停止、未删除、未覆盖。
- 若需回滚，必须先停止目标写入并审计/迁移目标切换后的增量；不得直接启动源造成双写或丢失生产增量。
