# 畅聊公网域名与统一 API 网关设计规格

日期：2026-08-18  
状态：已确认  
公网域名：`liuhetong888.com`、`www.liuhetong888.com`、`admin.liuhetong888.com`

## 1. 目标

将移动端、Matrix 客户端和管理端从本机 IP、局域网 IP、`localhost` 访问方式迁移到 HTTPS 域名入口。公网只暴露统一网关，不直接公开 Business API、Synapse、PostgreSQL、Redis、Worker、Bot 或内部管理端口。

本次迁移只改变客户端访问地址，不改变既有账号、Matrix ID、Matrix `server_name`、房间 ID、MXC URI、包名、资产代码或历史技术标识。

## 2. 已批准的域名映射

| 公网入口 | 用途 | 上游 |
| --- | --- | --- |
| `https://liuhetong888.com/api/v1/*` | Business API | `business-api:8082` |
| `https://liuhetong888.com/_matrix/*` | Matrix Client API 与媒体 | `synapse:8008` |
| `https://liuhetong888.com/.well-known/matrix/client` | Matrix 客户端发现 | 静态 JSON，`base_url=https://liuhetong888.com` |
| `https://liuhetong888.com/` | 现有 Web/Element 入口 | `element-web:80` |
| `https://www.liuhetong888.com/*` | 主域规范化 | `301` 到 `https://liuhetong888.com$request_uri` |
| `https://admin.liuhetong888.com/api/v1/*` | 管理端调用同一 Business API | `business-api:8082` |
| `https://admin.liuhetong888.com/` | 管理端入口边界 | 在独立管理前端交付前返回受控的 `404`，不得暴露 API 文档或内部控制台 |

`admin` 域名不绕过 Business API。所有管理操作继续使用现有业务身份、RBAC、TOTP、幂等、审计和审批规则。

## 3. TLS 与网关规则

1. 三个域名必须具有受信任的 TLS 证书；HTTP 统一跳转 HTTPS。
2. TLS 最低版本为 1.2，启用 TLS 1.3；证书和私钥只存在于服务器 Secret/证书目录。
3. 网关必须转发 `Host`、`X-Forwarded-For`、`X-Forwarded-Proto` 和请求 ID。
4. Business API 与 Matrix 分别使用独立 upstream；不得将数据库、Redis、Worker、Bot webhook 或 Synapse Admin API 暴露到公网。
5. `/_synapse/admin/*` 在公网入口显式拒绝。
6. API 请求体、上传体、WebSocket/长轮询超时按 Matrix 与媒体上传需求单独配置。
7. 安全响应头、速率限制和上传大小限制在网关层设置；不得记录密码、Token、消息正文或附件内容。

## 4. Matrix 兼容边界

- `SYNAPSE_PUBLIC_BASEURL=https://liuhetong888.com/`。
- `BUSINESS_MATRIX_PUBLIC_HOMESERVER_URL=https://liuhetong888.com/`，业务登录签发的 Matrix grant 必须返回该地址。
- 现有 `MATRIX_SERVER_NAME` 与 `BUSINESS_MATRIX_SERVER_NAME` 保持不变，避免修改既有 Matrix 用户 ID 和房间标识。
- `/.well-known/matrix/client` 返回：

```json
{"m.homeserver":{"base_url":"https://liuhetong888.com"}}
```

- E2EE 密钥、恢复密钥、房间密钥、消息明文和解密媒体不得进入网关日志或 Business API。

## 5. 移动端配置

发布构建固定注入：

```text
LIUHETONG_BUSINESS_API_URL=https://liuhetong888.com
LIUHETONG_MATRIX_HOMESERVER=https://liuhetong888.com
```

移动端实际业务路径仍由 `BusinessApiClient` 追加 `/api/v1`。Android Release 保持禁止明文 HTTP；不得把公网 Release 回退到 IP、`localhost` 或 cleartext。

本地开发可继续通过显式 `--dart-define` 使用本地环境，但本地值不得进入发布制品。

## 6. 服务端公开 URL

生产部署环境至少设置：

```text
PUBLIC_HOSTNAME=liuhetong888.com
SYNAPSE_PUBLIC_BASEURL=https://liuhetong888.com/
BUSINESS_MATRIX_PUBLIC_HOMESERVER_URL=https://liuhetong888.com/
BUSINESS_AVATAR_PUBLIC_BASE_URL=https://liuhetong888.com
EMAIL_VERIFICATION_PUBLIC_BASE_URL=https://liuhetong888.com
```

内部服务地址继续使用 Compose 服务名，例如 `http://synapse:8008/`，不得错误替换为公网地址。

## 7. 故障处理与发布顺序

上线顺序：

1. 确认三个 DNS 记录指向公网服务器。
2. 部署证书和网关配置。
3. 验证 HTTPS、Business API health、Matrix versions 和 well-known。
4. 更新服务端公开 URL 并滚动重启 API/Synapse。
5. 验证业务登录签发的 Matrix homeserver 为主域名。
6. 构建并安装域名版 APK。
7. 完成真实账号登录、会话恢复、消息收发和媒体下载验收。

任何阶段失败时，不发布域名版 APK；保持现有服务数据卷不变，回滚网关和公开 URL 配置。不得通过关闭 TLS 校验、开放内部端口或降低认证强度解决问题。

## 8. 测试与完成标准

- 三个域名 DNS 正确，HTTP 永久跳转 HTTPS。
- 三个域名 TLS 证书链、主机名和有效期校验通过。
- `GET /api/v1/health/live` 和 `GET /api/v1/health/ready` 返回 200。
- `GET /_matrix/client/versions` 返回 200。
- `GET /.well-known/matrix/client` 返回批准的 HTTPS 主域名。
- `www` 保留路径和查询参数跳转到主域名。
- `admin` 未认证访问不能获得受保护数据；RBAC/TOTP 行为不变。
- `/_synapse/admin/*`、数据库、Redis、Worker 和 Bot webhook 不可从公网访问。
- Flutter Release 制品中不包含局域网 IP、`localhost` 或明文 HTTP API 地址。
- 真实账号完成 Business 登录、Matrix token 登录、E2EE 消息同步和重启后会话恢复。
- 格式、静态分析、单元测试、集成测试、网关配置测试和仓库验证全部通过。

## 9. 当前上线阻塞事实

2026-08-18 探测结果：三个域名均解析到 `207.56.8.8`，但 HTTP 返回 `502`，HTTPS 443 拒绝连接。实施阶段必须先在公网服务器部署可用网关和证书，之后才能把移动端正式切换到域名入口。

