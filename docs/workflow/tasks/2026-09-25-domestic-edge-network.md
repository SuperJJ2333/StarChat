# 广州国内节点与 MI 6 间歇连接故障

## 恢复入口

- 用户 2026-09-25 要求使用 `Administrator@8.163.93.151:22` 阿里云节点优化国内连接，提出节点轮询；随后确认可改 GoDaddy DNS，并新增 `edge-cn-probe.liuhetong888.com` A 记录。不得要求账号密钥、短信验证码或用户身份。
- 执行工作树 `C:/Users/Administrator/.codex/worktrees/performance-debug-mi6/StarChat`，分支 `codex/performance-debug-mi6`。本任务拥有新[计划](../../superpowers/plans/2026-09-25-domestic-edge-network.md)、本记录与本轮验证目录；原性能/认证任务文档由 root 更新。阿里云/源站初审代理只读，未改服务器。
- 当前已安装 MI 6 2177，生产接收端 `25954c6a…` healthy/零重启。原业务与 Matrix 源站继续承载正式流量；测试 DNS 仅新增独立子域名。阿里云 Caddy 已增量启用只允许两个公开 GET 的试点站点；主域名未切换。
- 阶段 1 范围：备份/验证/增量添加仅公开健康端点的 Caddy 站点，证书与 MI 6 端到端探测。阶段 2 的认证限流、TURN 域名分离和正式 DNS 切流以专项 ADR、失败测试与安全复核为门禁。

## 验收台账

| ID | 预期 | 已有证据 | 状态 |
| --- | --- | --- | --- |
| NET-CN-01 | 定位 MI 6 到源站与广州节点的差异 | 10 轮同窗口、两条公开路径：经边缘 20/20 为 200，直连源站 8/20 为 200、12/20 `curl` 28 超时；设备 curl 禁用代理、校验证书、解析目标符合预期 | 公开路径的故障分段已证实；认证/同步未测 |
| NET-CN-02 | 测试域名 HTTPS 证书与公开路径 | 权威和本地 DNS 均解析到新节点，TTL 600 秒；Caddy 候选 validate/reload、MI 6 Business ready/Matrix versions 200、证书 SAN、非公开路径 404 | 阶段 1 通过 |
| NET-CN-03 | 保留 Employ26 服务 | 原 22 行站点块只追加试点块，配置/运行候选一致；原 IP HTTP 308 保持。原 IP HTTPS 握手试点前后均失败，不能称其 HTTPS 已验收 | 已证实原行为未恶化；原 IP HTTPS 既存问题另案处理 |
| NET-CN-04 | 登录/Matrix/媒体可经节点且限流仍按真实 IP | 实际为边缘 Caddy → 源站宿主 Caddy → Docker Nginx → Uvicorn；当前尚无逐跳可信真实 IP 配置；客户端与 Matrix 绑定主域名 | 阶段 2 待 ADR、失败测试和安全复核 |
| NET-CN-05 | 主域名切流不破坏 TURN | 生产 TURN UDP/TCP/TLS URI 均使用主域名，证书不含独立 TURN 子域名 | 阶段 2 阻断主域名切流 |
| NET-CN-06 | 边缘和源站 HTTPS 证书可持续续期 | 边缘仅有测试子域证书；源站主域名/admin/www Certbot 是 standalone 验证，到期 2026-11-16。源站 80/443 当前由 Caddy 占用且无 Certbot pre/post hook，现有续期本身亦有潜在冲突；主域名切流会再失去验证路径 | 阶段 2 阻断主域名切流；现有证书续期另须修复 |
| NET-CN-07 | 节点可承载真实长轮询/大媒体且不影响 Employ26 | 广州 Windows ECS 总 1966 MiB RAM，16:39 HKT 五次可用 271–303 MiB，与 Employ26 共用 Caddy/80/443；公开健康 GET 不能代表生产容量 | 阶段 2 待扩容/目标负载压测及回退演练 |

## 阶段计时与下一步

| 阶段 | 时间 HKT | 证据 | 下一步 |
| --- | --- | --- | --- |
| 问题转向与只读审计 | 2026-09-25 14:53 后；结束时间待补 | MI 6/阿里云/源站分段探测、DNS、Caddy、Nginx、TURN 现状 | 测试域名试点 |
| 测试 DNS | 2026-09-25 15:42 前 | 权威和本地 A 记录正确，TTL 600 秒；主域名仍在源站 | Caddy 备份、候选验证与发布 |
| 公开 HTTPS 试点部署 | 2026-09-25 16:07–16:08 | 原配置 ACL 保留备份，候选 SHA256 `a20ca505…`，门禁脚本退出 0；MI 6 两条公开路径 200、非公开 404、证书 SAN 正确；失败自动回退已布置 | 同窗口对照 |
| MI 6 同窗口对照 | 2026-09-25 16:18–16:22 | [原始匿名证据](../../verification/artifacts/2026-09-25/domestic-edge-network/paired-public-20260925T0821569800587Z.json)：边缘 20/20、源站 8/20；Business 边缘 P50/P95 98.7/123.9 ms，Matrix 边缘 99.1/341.9 ms | 完整业务代理门禁设计 |
| 存活与 DNS 复查 | 2026-09-25 16:25 | 生产 API 镜像 `25954c6a…` healthy/0 restart；试点 A 仍指广州、主域名 A 仍指源站，TTL 均 600 秒 | 认证、TURN、Matrix 会话路由设计 |

此样本支持源站直连链路存在间歇问题，但只证明公开 GET 经边缘可达，不等于短信送达、登录、Matrix `/sync`、媒体或通话已修复。阶段 1 不迁移认证或资金请求，也不改变主域名和 TURN。详细证据和剩余门禁见[试点报告](../../verification/2026-09-25-domestic-edge-network.md)。
