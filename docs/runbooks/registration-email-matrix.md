# 注册邮件与 Matrix 开户运行手册

## 适用范围

本文记录注册验证邮件的本地 Mailpit、生产 SMTP 与 Matrix 自动开户配置。邮件验证成功后发布幂等的 `identity.matrix.provision.requested` Outbox 事件，由 Worker 调用 Synapse Admin API。

## 本地 Mailpit

1. 保持 `.env` 中 `SMTP_HOST=mailpit`、`SMTP_PORT=1025`、`SMTP_SECURITY=none`。
2. 启动服务：`docker compose up -d mailpit business-worker`。
3. Mailpit Web UI：`http://127.0.0.1:8025`。
4. SMTP 仅绑定宿主机 `127.0.0.1:1025`；Compose 内 Worker 使用 `mailpit:1025`。

邮件正文包含 6 位验证码和验证链接。验证内容属于临时凭证，不得复制到验证文档、工单、日志或聊天消息。

## 生产 SMTP

生产环境必须显式设置：

- `SMTP_HOST`、`SMTP_PORT`
- `SMTP_SECURITY=none|starttls|ssl`
- `SMTP_USERNAME` 与 `SMTP_PASSWORD`（必须同时提供或同时为空）
- `SMTP_FROM`
- `SMTP_TIMEOUT_SECONDS`
- `EMAIL_VERIFICATION_PUBLIC_BASE_URL`

STARTTLS 与隐式 SSL 互斥。`SMTP_PASSWORD` 只能由部署环境或 Secret Manager 注入，不写入仓库。发送失败对 Worker 仅返回脱敏的 `SMTP delivery failed`，Outbox 将按原事件重试。

## Matrix 自动开户

Worker 与 Business API 必须配置：

- `MATRIX_HOMESERVER_URL`：Compose 内使用 `http://synapse:8008/`。
- `MATRIX_SERVER_NAME`：必须与 Synapse 的 `server_name` 一致。
- `SYNAPSE_ADMIN_ACCESS_TOKEN`：具有用户管理权限的管理员 Token，只能由部署环境或 Secret Manager 注入。
- `MATRIX_PROVISION_SECRET`：至少 16 字节，专用于按 Business `user_id` 派生开户密码；生产环境必须替换示例值并保持稳定。

Worker 使用规范化 Business username 生成稳定 localpart，并以幂等 `PUT /_synapse/admin/v2/users/{mxid}` 创建账号。若 PUT 超时，必须先对完全相同的 MXID 执行 GET：查到用户即按成功处理；无法确认时返回 `MATRIX_PROVISION_RESULT_UNKNOWN`，保留 Outbox 供重试。成功后通过 Identity 公共任务接口原子写入 `matrix_user_id` 并将账号置为 `ACTIVE`。

开户密码只在 Worker 请求内存中派生，不写入数据库、Outbox、审计或日志。管理员 Token 与派生 secret 也不得输出到日志。

## Matrix 一次性登录令牌

Business API 通过 Compose 将 `SYNAPSE_ADMIN_ACCESS_TOKEN` 注入为 `BUSINESS_SYNAPSE_ADMIN_ACCESS_TOKEN`，并使用以下配置：

- `BUSINESS_MATRIX_HOMESERVER_URL`：Synapse Admin API 内部地址。
- `BUSINESS_MATRIX_PUBLIC_HOMESERVER_URL`：返回给客户端的公开 homeserver 地址。
- `BUSINESS_MATRIX_SERVER_NAME`：与 Synapse `server_name` 一致。
- `BUSINESS_MATRIX_LOGIN_TOKEN_EXPIRES_IN`：固定 60 秒，必须与 Synapse `login_via_existing_session.token_timeout: 1m` 一致。

受认证的 `POST /api/v1/auth/matrix-login-token` 只读取 Business access token 的 `sub`，再从 Identity 用户记录取得绑定 MXID；请求方不能提交或覆盖目标 MXID。接口返回 `login_token`、`homeserver`、`expires_in`，Token 不写数据库、Outbox、审计 details 或日志。审计仅记录 actor、action、result 与稳定 reason code。

Synapse v1.132 的 Admin `POST /_synapse/admin/v1/users/{mxid}/login` 返回的是短期代理 access token，而不是可供 `m.login.token` 使用的令牌。Business API 随即用该短期代理凭证调用 `POST /_matrix/client/v1/login/get_token`，只把第二步返回的 `login_token` 交给客户端；两个上游 Token 都不得记录或持久化。

客户端必须立即以 Matrix `m.login.token` 使用该 Token；Token 使用一次或到期后失效。Synapse 拒绝签发时 Business API 返回稳定错误码 `MATRIX_LOGIN_TOKEN_FAILED`，不得把 Synapse 响应或 Token 写入错误文本。

## 排查

1. `docker compose ps mailpit business-worker`
2. `docker compose logs business-worker --since 10m`，确认日志没有邮箱正文、验证码、Token 或 SMTP 凭证。
3. 检查 Mailpit 健康状态，但不要将收件箱正文写入验证证据。
4. 检查 `identity.email` Outbox 事件只包含内部 `user_id` 与 `challenge_id`，不含密码、验证码或验证 Token。
5. 检查 `identity.matrix` 重试记录；若错误码为 `MATRIX_PROVISION_RESULT_UNKNOWN`，先按 MXID 查询 Synapse，再决定是否继续重试。
