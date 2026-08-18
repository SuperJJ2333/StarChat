# 畅聊生产环境停机迁移设计规格

日期：2026-08-18  
状态：已确认立即停机迁移  
来源：本机运行中的 `starchat` Compose  
目标：`liuhetong-prod`（`207.56.8.8:23421`）

## 1. 迁移范围

必须迁移：

- Business PostgreSQL：账号、身份、好友、朋友圈、账本、红包、钱包、审计、Outbox 和会话。
- Synapse PostgreSQL：账号、房间、事件密文、设备、访问令牌和同步状态。
- Synapse signing key、media store 和生成配置所需的连续性秘密。
- Business 私有媒体。
- Matrix Bot 加密 store 与幂等状态。
- 现有 Matrix `server_name=matrix.localhost` 及所有历史 Matrix ID。

不迁移：

- Redis 临时缓存；目标使用空缓存启动。
- 构建缓存、Flutter APK 中间文件、Mailpit 邮件、日志和临时截图。
- 本机 `.git`、worktree 元数据或任何无关项目数据。

## 2. 已确认的实际源数据

运行容器跨两个工作目录挂载数据，迁移必须以 `docker inspect` 的实际 Mount 为准：

- Synapse PostgreSQL：`.worktrees/auth-profile-contact-ui-modernization/data/postgres`，逻辑库约 18 MB。
- Synapse data/media/signing：`.worktrees/auth-profile-contact-ui-modernization/data/synapse`。
- Business PostgreSQL：`data/business-postgres`，逻辑库约 9.6 MB。
- Business API media：`data/business-media`。
- Worker media 补充源：`.worktrees/auth-profile-contact-ui-modernization/data/business-media`。
- Bot store：`.worktrees/auth-profile-contact-ui-modernization/data/bot`。

不得误用根目录下未被运行容器挂载的同名 Synapse/PostgreSQL 目录作为唯一来源。

## 3. 停机和一致性顺序

1. 记录源容器、镜像、数据库版本和健康状态。
2. 停止公网/客户端写入入口：Business API、Worker、Matrix Bot、Synapse、Element、TURN。
3. 保持两个 PostgreSQL 容器运行，等待活动写事务归零。
4. 分别执行 `pg_dump -Fc`，同时记录非敏感结构版本和关键表行数。
5. 归档 signing key、Synapse media/data、Business media 和 Bot store。
6. 对每个导出文件生成 SHA-256；通过 SSH/SCP 加密传输。
7. 导出完成前不得启动源写入服务。

账本在停机后通过数据库一致性查询验证每个资产借贷平衡；禁止在迁移过程中修正或补写账本。

## 4. 目标生产环境

- Ubuntu 主机启用时间同步，时区可保持 UTC。
- 安装 Docker Engine/Compose 与 Nginx/证书工具的受支持固定版本。
- 项目部署到 `/opt/starchat`，运行数据位于该部署根的忽略目录。
- PostgreSQL、Redis、Worker、Bot 和内部管理接口不绑定公网地址。
- Nginx 是唯一 80/443 入口，使用已批准的三个域名拓扑。
- TLS 证书覆盖根域、www 和 admin 域。
- Business API 和 Synapse 只通过容器网络或 loopback 接收网关流量。

## 5. 秘密连续性

从本机 `.env` 安全迁移但不输出以下连续性秘密：

- Synapse macaroon/form/registration secrets 和 admin/bot credentials。
- Matrix provision/webhook credentials、bot access token 和房间路由配置。
- Business JWT、TOTP、邮箱验证、密码重置和头像签名 secrets。
- Business/PostgreSQL 数据库凭据及现有服务绑定所需配置。

Synapse signing key作为文件迁移。TURN secret 可在目标生成新强随机值。SSH 初始密码不写入迁移包，完成密钥认证后不再使用。

## 6. 恢复顺序

1. 部署代码和不含秘密的生产配置模板。
2. 写入权限为 owner-only 的目标 `.env` 和数据目录。
3. 启动两个空 PostgreSQL 16.9 容器。
4. 使用 `pg_restore --clean --if-exists --no-owner` 恢复 Synapse 与 Business 数据库。
5. 恢复 signing key、媒体和 Bot store，校验 SHA-256。
6. 渲染 `SYNAPSE_PUBLIC_BASEURL=https://liuhetong888.com/`，保持 Matrix `server_name` 不变。
7. 启动 Synapse、Business API、Worker、Bot、Redis、Element 和 TURN。
8. 所有内部健康检查通过后部署 Nginx 与受信任证书。

## 7. 验证门禁

必须全部通过：

- 源/目标 Business 关键表行数相等。
- 源/目标 Synapse 用户、房间和事件计数相等。
- 账本按资产平衡，无浮点重算或 Matrix 派生数据。
- signing key SHA-256、媒体归档 SHA-256 和 Bot store SHA-256 相等。
- 现有两个测试账号可完成 Business 登录和 Matrix token 登录。
- 既有好友、聊天房间、历史消息密文和头像可见。
- `verify_public_domains.ps1` 全部通过。
- Android 域名版可登录、发送和接收 E2EE 消息，重启后会话恢复。
- `/_synapse/admin/*`、数据库、Redis 和 Bot webhook 公网不可达。

## 8. 回滚

目标验证失败时停止目标写入服务，不修改目标失败数据；重新启动本机原 Compose 写入服务。本机数据目录、数据库容器和 signing key 在验收完成前不得删除或覆盖。

## 9. 完成标准

只有目标验证门禁全部通过、域名版真实登录成功且源数据保持可回滚时，迁移状态才能标记为完成。否则状态为阻塞或已回滚，并保留验证证据。
