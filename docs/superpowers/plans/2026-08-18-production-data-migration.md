# 畅聊生产数据停机迁移实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在可回滚停机窗口内，把本机现有 Business、Matrix、媒体、账号和密码学身份迁移到 `liuhetong-prod`，部署 HTTPS 生产环境并完成域名版真实验收。

**Architecture:** 停止所有写入者后使用 PostgreSQL custom-format logical dump；以实际容器 Mount 为准归档 signing key、媒体和 Bot store；通过 SSH 加密传输到空白 Ubuntu 目标。目标使用固定版本容器恢复数据，保持 Matrix `server_name` 不变，由 Nginx 为三个域名提供 TLS 统一网关。

**Tech Stack:** PostgreSQL 16.9、Synapse 1.132.0、Docker Engine/Compose、Nginx 1.27.5、PowerShell 7、OpenSSH、Flutter。

## Global Constraints

- 规格：`docs/superpowers/specs/2026-08-18-production-data-migration-design.md`。
- ADR：`docs/adr/0005-production-cutover-preserve-matrix-identity.md`，状态必须为 Accepted。
- 不改 Matrix `server_name`、signing key、Matrix ID、房间 ID、MXC URI 或 E2EE 边界。
- 不改写账本、钱包或红包业务数据；只从 Business PostgreSQL 迁移。
- 不把 `.env`、数据库 dump、媒体、私钥、Token 或恢复密钥加入 Git/日志。
- 源数据在目标全部验收前不得删除、覆盖或启动新的写迁移。
- 公网验收失败时不发布 Release APK，执行回滚或保持迁移阻塞。

---

### Task 1: 接受决策、迁移清单与双重评审

**Files:**
- Modify: `docs/adr/0005-production-cutover-preserve-matrix-identity.md`
- Create: `docs/verification/2026-08-18-production-data-migration.md`

- [x] **Step 1: 将 ADR 标记为 Accepted**
- [x] **Step 2: 记录实际 Docker mounts、数据库版本、源/目标容量和停机开始时间**
- [x] **Step 3: 完成 Domain review**：确认 Business 数据唯一来源、Matrix 数据唯一来源、账本不从 Matrix 派生、两个媒体目录做安全合并。
- [x] **Step 4: 完成 Quality/Security review**：确认秘密不进 Git/日志、目标端权限 owner-only、签名 key 校验、回滚源保持完整。

### Task 2: 停止写入并证明数据库静止

**Files:**
- Modify: `docs/verification/2026-08-18-production-data-migration.md`

- [x] **Step 1: 记录停机前容器健康状态**
- [x] **Step 2: 停止写入服务**

```powershell
docker compose stop business-api business-worker matrix-bot synapse element-web coturn
```

- [x] **Step 3: 保持 `postgres` 和 `business-postgres` 运行，查询 `pg_stat_activity`**
- [x] **Step 4: 确认 API、Worker、Bot、Synapse 不再接受写入并记录 UTC/Hong Kong 停机时间**

### Task 3: 一致性导出与源端验证

**Files:**
- Runtime only: ignored `migration-artifacts/2026-08-18/**`
- Modify: `docs/verification/2026-08-18-production-data-migration.md`

- [x] **Step 1: 创建权限受限的迁移目录**
- [x] **Step 2: 使用 `pg_dump -Fc` 导出 Synapse 数据库**
- [x] **Step 3: 使用 `pg_dump -Fc` 导出 Business 数据库**
- [x] **Step 4: 记录数据库 schema revision、用户/房间/事件及 Business 关键表行数**
- [x] **Step 5: 执行账本按资产平衡查询并要求差额为 0**
- [x] **Step 6: 归档实际 Synapse data/media/signing、Business media 和 Bot store**
- [x] **Step 7: 对 dump 与归档生成 SHA-256 manifest**

### Task 4: 目标服务器基础环境

**Files:**
- Runtime only: `/opt/starchat`, `/opt/starchat-migration`, `/etc/nginx`, `/etc/letsencrypt`
- Modify: `docs/verification/2026-08-18-production-data-migration.md`

- [ ] **Step 1: 启用 systemd 时间同步并验证 NTP synchronized**
- [x] **Step 2: 安装固定版本 Docker Engine/Compose、Nginx 与 Certbot**
- [x] **Step 3: 配置防火墙只开放 80、443、23421 和批准的 TURN 端口**
- [x] **Step 4: 创建 owner-only 部署和数据目录**
- [x] **Step 5: 通过 `git archive`/受控 tar 传输仓库，不传 `.git`、本地 data 或构建缓存**

### Task 5: 安全传输与恢复

**Files:**
- Runtime only: source/target migration artifacts and target `.env`

- [x] **Step 1: 从本机 `.env` 生成不输出秘密的生产 `.env`，公开 URL 全部替换为 HTTPS 域名**
- [x] **Step 2: 保留 Matrix/Business 连续性 secrets，生成新的 TURN secret**
- [x] **Step 3: 通过 SCP 传输 dump、归档、checksum manifest 和生产 `.env`**
- [x] **Step 4: 目标校验所有 SHA-256**
- [x] **Step 5: 启动两个空 PostgreSQL 16.9 容器并恢复 custom dump**
- [x] **Step 6: 恢复 signing key、Synapse media、Business media 和 Bot store，设置最小权限**
- [x] **Step 7: 渲染配置并确认 `server_name=matrix.localhost`、public URL 为主域**

### Task 6: 启动生产服务与 TLS 网关

**Files:**
- Runtime only: rendered production configs/certificates

- [x] **Step 1: 启动 Redis、Synapse、Business API、Worker、Bot、Element 和 TURN**
- [x] **Step 2: 验证容器内 health、迁移版本和日志无 fatal/error**
- [x] **Step 3: 以 HTTP challenge 获取覆盖三个域名的受信任证书**
- [x] **Step 4: 部署渲染后的 Nginx 配置并运行 `nginx -t`**
- [x] **Step 5: 启动 80/443 网关并确认内部端口未暴露公网**

### Task 7: 迁移一致性和产品验收

**Files:**
- Modify: `docs/verification/2026-08-18-production-data-migration.md`

- [x] **Step 1: 比较源/目标 Business 关键表行数和账本平衡结果**
- [x] **Step 2: 比较源/目标 Synapse 用户、房间、事件计数**
- [x] **Step 3: 比较 signing/media/Bot SHA-256 manifest**
- [x] **Step 4: 运行 `scripts/verify_public_domains.ps1` 并要求 PASS**
- [ ] **Step 5: 使用已有测试账号完成 Business + Matrix 登录、历史房间/消息/头像验证**
- [ ] **Step 6: 安装域名 Debug 验收 APK，验证 E2EE 消息、重启会话恢复**
- [x] **Step 7: 确认公网拒绝 Synapse Admin、PostgreSQL、Redis 和 Bot webhook**

### Task 8: 切换完成或回滚

**Files:**
- Modify: `docs/verification/2026-08-18-production-data-migration.md`

- [ ] **Step 1: 所有门禁通过时记录目标为 authoritative，源保持停止和可回滚**
  - 运行状态说明：公网目标已经接受写入，运营上必须视为 authoritative；但 NTP 和两个测试账号 E2EE 门禁尚未关闭，因此本计划不标记全部完成。源保持停止，回滚前必须处理目标增量。
- [ ] **Step 2: 任一关键门禁失败时停止目标写入并重启源服务**
- [x] **Step 3: 运行仓库验证、`git diff --check` 并提交非秘密证据**
- [x] **Step 4: 记录停机结束时间、总时长、APK 和公网状态**
