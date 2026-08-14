# 注册邮件与 Matrix 开户运行手册

## 适用范围

本文记录注册验证邮件的本地 Mailpit 与生产 SMTP 配置。Matrix 自动开户由后续任务补充；当前邮件成功验证只发布幂等的 `identity.matrix.provision.requested` Outbox 事件。

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

## 排查

1. `docker compose ps mailpit business-worker`
2. `docker compose logs business-worker --since 10m`，确认日志没有邮箱正文、验证码、Token 或 SMTP 凭证。
3. 检查 Mailpit 健康状态，但不要将收件箱正文写入验证证据。
4. 检查 `identity.email` Outbox 事件只包含内部 `user_id` 与 `challenge_id`，不含密码、验证码或验证 Token。
