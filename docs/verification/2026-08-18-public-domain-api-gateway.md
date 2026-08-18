# 公网域名统一 API 网关验证证据

日期：2026-08-18

## 设计与计划

- 规格：`docs/superpowers/specs/2026-08-18-public-domain-api-gateway-design.md`
- 计划：`docs/superpowers/plans/2026-08-18-public-domain-api-gateway.md`

## 测试先行证据

- 网关策略测试首次失败于缺少 `business_api_upstream`，实现主域、www、admin 和 Synapse Admin 拒绝规则后通过。
- 生产配置契约测试首次失败于缺少 `WWW_PUBLIC_HOSTNAME`，补充环境样例和移动发布命令后通过。
- 公网验收脚本结构测试首次失败于脚本不存在，实现 DNS、TLS、重定向、Business API、Matrix、well-known 和管理边界检查后通过。

## 当前公网基线

- `liuhetong888.com`、`www.liuhetong888.com`、`admin.liuhetong888.com` 均解析到 `207.56.8.8`。
- HTTP 主域和 www 当前返回 `502`，没有按批准规则跳转。
- 三个域名的 HTTPS 请求均无法建立受信任 TLS 连接。
- Business API、Matrix、well-known 和 admin 公网检查因此失败。
- `scripts/verify_public_domains.ps1`：`FAIL (13 checks)`。

## 远端部署通道

- `207.56.8.8:22` TCP 可连接，且主机已存在于本机 known_hosts。
- 已发现历史 SSH 用户名为 `root`，但 BatchMode 连接被远端立即关闭，当前没有可用的非交互授权会话。
- 未猜测密码、未修改远端 SSH 设置、未开放临时端口。

当前远端上线状态：`BLOCKED`。解除条件是提供已授权的 SSH/部署代理会话，并在服务器安装覆盖三个域名的受信任证书。
