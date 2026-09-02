# 2026-08-28 生产 API 与域名路由修复

## 根因
公网 Caddy 将请求反向代理到 `127.0.0.1:9443` 时没有传递客户端原始 `Host`。Nginx 因而接收到默认上游主机名，落入默认 Element Web server 块，使 `www` 和 `admin` 都返回 Element 页面。

## 变更
- 服务器：`207.56.8.8`（Ubuntu，Caddy → Docker Nginx Gateway → Business API/Element/Synapse）。
- `/etc/caddy/Caddyfile`：在 `reverse_proxy 127.0.0.1:9443` 添加 `header_up Host {host}`。
- 变更前创建：`/etc/caddy/Caddyfile.bak-20260828T055048Z`。
- 使用 `caddy validate --config /etc/caddy/Caddyfile` 验证成功后执行 `systemctl reload caddy`；未重启聊天 API、Synapse 或数据库容器。

## 验证
- `https://liuhetong888.com/`：HTTP 200，Element（既有 APP/Matrix Web 入口）。
- `https://www.liuhetong888.com/`：HTTP 200，`ChatFlow 畅聊 · 可信沟通平台`。
- `https://admin.liuhetong888.com/`：HTTP 200，`ChatFlow 畅聊 · 管理后台`。
- `https://admin.liuhetong888.com/api/v1/health/live`：HTTP 200，`{"ok":true,"service":"畅聊 Business API"}`。
- `starchat-business-api-1`：healthy；`starchat-synapse-1`：healthy；Gateway 运行中。
- Business API 最近 6 小时未发现应用 ERROR/Traceback，Gateway 无上游错误。

## 回滚
`cp /etc/caddy/Caddyfile.bak-20260828T055048Z /etc/caddy/Caddyfile && caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy`
