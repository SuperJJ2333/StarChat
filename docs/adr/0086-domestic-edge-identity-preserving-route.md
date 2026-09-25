# ADR-0086：国内 HTTPS 边缘节点保留 Matrix 身份及认证限流

- 日期：2026-09-25。
- 状态：**Proposed，尚未批准或部署正式业务路由**。
- 依据：[分阶段计划](../superpowers/plans/2026-09-25-domestic-edge-network.md)、[公开试点验证](../verification/2026-09-25-domestic-edge-network.md)。

## 背景

MI 6 同窗口公开 HTTPS 对照中，经广州节点 20/20 成功、直连原站 8/20 成功，其余 12 次超时。客户端 Business URL、Matrix grant、本地加密数据库槽和 Matrix 会话绑定均使用主域名；替换成测试子域名会破坏既有身份连续性。主域名又同时用于 TURN 3478/5349。广州 ECS 目前只有 271–303 MiB 可用 RAM，与 Employ26 共用，尚未通过正式流量容量测试。

## 拟议决策

1. 客户端 Business/Matrix 对外 URL 与登录 grant 继续使用 `liuhetong888.com`，Matrix 内部 `server_name=matrix.localhost` 和已有 E2EE 会话均保持原值。不得把内部 `server_name` 误改为公网域名。不做多 A 随机轮询，不自动重放验证码、登录或资金 POST。公开健康试点独立存在，不能承载真实鉴权。
2. 正式入口使用透明 HTTPS 边缘，广州本机独立私钥和可自动续签的主域名证书；广州→源站使用经过证书链与目标名称校验的 TLS。源站 Caddy 公网证书和内层 Certbot/TURN 证书分别解决续签。任何一段公网链路不得禁用证书验证。
3. 先迁出 TURN 到指向源站的独立域名；服务端证书、Synapse URI 与 coturn 挂载/续期一致，并实测 UDP/TCP/TLS relay。主域名 A 迁走后，缓存的旧 `turn(s):liuhetong888.com:3478/5349` 会错误落到广州；须证明旧 URI 与活跃通话均已排空，或在广州提供经真实 relay 测试的临时旧端口转发。仅更新 Synapse URI 不构成过渡完成。没有通话验收不得改主域名 A 记录。
4. 认证与通话限流使用逐跳可信客户端 IP：广州 Caddy 清洗外部来路的 XFF；源站宿主 Caddy 仅信任经隔离、验明身份的广州代理出口 `8.163.93.151/32`，向 Nginx **覆盖** `X-Forwarded-For: {client_ip}` 为单一已解析 IP，不能沿用默认增补链；Docker Nginx 仅信任实际直连宿主网关 `172.18.0.1/32`，向 Uvicorn **覆盖** `X-Forwarded-For: $remote_addr` 为单一 IP；Uvicorn 现有仅信任 Nginx 容器 `172.18.0.12` 的范围保持。上述地址来自生产只读探针；部署前重新核验。不得将广州公网 IP 配成 Nginx 的直接可信 peer。**当前广州主机与 Employ26 共用、Caddy 以 SYSTEM 运行；仅信任该公网 IP 等于信任整台主机上所有可出网进程。** 正式鉴权前应使用独立边缘主机，或证明隔离及代理身份验证（如受限客户端证书）使非 StarChat 进程无法伪造转发身份。
5. 边缘代理保留原 HTTP 方法、路径、鉴权头、流式与长轮询语义。拒绝 `/_synapse/admin/`；不得缓存或自动重放写请求。Matrix 登录 broker、加密媒体、`/ios-call/`、well-known、Business API 与资金边界均应按现网路由逐项验收。
6. 正式切流以容量压测和回退演练为门禁。目标 RAM 由代表性长轮询、媒体、认证并发的峰值加实测余量确定，不凭公开健康 GET 给固定规格。GoDaddy 普通 A 记录不能实现可靠的国内优选或故障切换；若需要按地区选路，应使用有健康检查的 DNS/流量管理并保留单一 Matrix 身份。

## 必须先失败再修复的验证

- 未配置可信链时，广州路径两个独立客户端可能合并到同一 OTP/`/ios-call/` 限流桶；修复后两者分别计数。直连源站伪造 `X-Forwarded-For` 不得改变计数身份；广州入口携带伪造头也不得覆盖真实对端；同机其他进程直接向源站自填 XFF 也不得获得 StarChat 代理身份。
- 同一持久 Matrix 会话经边缘访问，设备号、SQLCipher/Olm 数据和已有消息保持；`/sync` 超过 30 秒、断线取消、加密媒体上传下载与 100 MiB 限额通过。业务 API、红包/钱包幂等键和一次性验证码不被边缘重试。
- DNS 切换前证实边缘、源站 Caddy、内层 Certbot/TURN 的证书签发、自动续期和失败告警；边缘故障按冻结配置/旧 DNS 回退。按实测确认旧 URI/活跃通话已排空，或验证广州旧端口临时转发；切流不得使旧 URI 指向无 TURN 服务的节点。
- 广州节点容量、Employ26 健康、证书和 Caddy 进程在代表性并发和回退后保持。中国内地正式接入前核实 ICP 备案/接入状态。

本 ADR 涉及认证限流身份判定；按仓库受保护变更规则，仍需用户批准、Domain Review、Quality/Security Review 与上述失败/通过证据，才可部署正式流量。
