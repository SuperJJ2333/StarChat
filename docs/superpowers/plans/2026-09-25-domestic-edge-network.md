# 国内 HTTPS 节点接入与网络故障验证

**授权：** 用户于 2026-09-25 要求使用阿里云服务器优化国内连接，并已新增 `edge-cn-probe.liuhetong888.com` 的 A 记录。该记录只用于试点；未授权破坏现有通话或 Employ26 服务。

## 已核实的边界

- MI 6 到广州阿里云节点 TCP 22/443 六次分别约 6–23 ms；广州节点到现有 Business/Matrix 公开 HTTPS 四轮 66–81 ms（另有一次 Business 1145 ms）。旧 MI 6 到主域名两轮 5/12 超时，新一轮 6/6 成功，故故障间歇出现。
- 阿里云 Windows Server 2019 已由 Employ26 的 Caddy 2.11.4 占用 80/443；只能增量添加独立站点，先备份、验证、重载，不能替换现有配置。主域名 DNS 当前仍指向源站。
- 客户端和 Matrix 会话绑定主域名；客户端随机轮询会触及一次性验证码和其它非幂等请求。现有 TURN 3478/5349 也解析主域名，直接切主域名 DNS 会破坏通话。正式路径实际经过广州 Caddy → 源站宿主 Caddy → Docker Nginx → Uvicorn；其中各跳尚未建立严格的真实客户端 IP 信任链，直接开放认证/通话代理会把用户限流合并。

## 阶段 1：不接入用户流量的试点（2026-09-25 已完成）

1. 核实测试 A 记录在权威 DNS 与本地解析都指向阿里云；主域名记录不变。
2. 冻结 Caddy 原文件 SHA、服务进程命令、站点健康和 ACL。私有备份保留原 ACL。生成只新增 `edge-cn-probe` 站点的配置；仅允许 GET 的 Business ready 和 Matrix versions，其他路径返回 404。上游使用源站固定 IP，TLS SNI/证书及 Host 仍为主域名，避免日后 DNS 回环；不缓存、不重试业务写入、不保存 URL/身份日志。
3. 先验证候选 Caddyfile；reload 后检查原 Employ26 站点未变化、测试域名证书 SAN 和 HTTPS 健康。失败立即还原备份并 reload。
4. 从 MI 6 对测试域名与现有主域名做同窗口、同公开端点的有限重复测量；只保存状态、DNS/TCP/TLS/TTFB/总耗时及类别，不保存 IP、URL、响应体或身份。阿里云与源站也测同路径。若节点本身不稳定，停止扩展。

阶段 1 实际结果：`edge-cn-probe` HTTPS 已启用且仅开放上述两条公开 GET；MI 6 同窗口 10 轮边缘 20/20 成功，直连原站 8/20 成功、12/20 超时。正式客户端、主域名与 TURN 未改变。细节和原始匿名记录见[试点验证](../../verification/2026-09-25-domestic-edge-network.md)。

## 阶段 2：全业务路径的设计与安全门禁

1. 为 TURN 准备独立域名、指向原源站的 DNS、含该域名的有效证书与续期路径；更新 Synapse TURN URI 并验证 UDP/TCP/TLS relay。主域名 A 迁走后缓存的旧 `turn(s):liuhetong888.com:3478/5349` 会落到未提供 TURN 的广州节点。切流前必须证明旧 URI/活跃通话已排空，或在广州提供经真实 relay 测试的临时旧端口转发。不得仅切主域名 A 记录。
2. 建立整条真实 IP 信任链：边缘 Caddy 清洗外部输入的转发头；源站宿主 Caddy 只信任阿里云实际固定出口 IP，并以 `header_up X-Forwarded-For {client_ip}` 覆盖为单一 IP；Docker Nginx 只信任直连的源站 Caddy 网关，并以 `proxy_set_header X-Forwarded-For $remote_addr` 覆盖为单一解析 IP 交给 Uvicorn；Uvicorn 继续只信任 Nginx 网关。不得把阿里云地址直接配为 Nginx 的直连可信 peer，因为 Nginx 实际连接来自源站 Caddy。广州主机还承载 Employ26，单纯信任该公网 IP 等于信任同机任一可出网进程，正式鉴权前应独立部署或证明进程隔离与代理身份验证。分别用直连、边缘入口及同机其他进程伪造 XFF、两个不同客户端和验证码/`/ios-call/` 限流失败用例验证。此项影响认证限流，先写 ADR、失败测试并完成领域与质量/安全复核。
3. 扩展边缘为同域名透明 HTTPS 代理，源站固定地址使用与最终源站证书匹配的 SNI（主域名 DNS-01 续期或独立 `origin` 名均须实测），并验证传入 Nginx 的原业务 Host/路由不变；覆盖 Business、Matrix 长轮询/登录/加密媒体、推送、`/ios-call/`、well-known。流式和媒体限额不比源站更严；拒绝 `/_synapse/admin/`；不缓存或重放非幂等请求。生产源站模板缺 `/ios-call/`，不得用仓库模板直接覆盖实际配置。
4. 先用保持真实 SNI/证书校验的定向请求验证完整代理，再做有限设备灰度。只有 HTTPS、认证限流、Matrix E2EE、媒体、WebRTC/TURN 与回退均通过，才计划主域名 DNS 切流。GoDaddy 普通 A 记录是**全球切换**，不能称为国内区域切流；若要按地区调度，须另有经验证的健康检查与地理路由能力。不要新增无健康检查的多 A 随机轮询。

同域名灰度还必须解决边缘主域名证书：当前 Caddy 只为测试子域取得证书，主域名仍指源站，不能以 `curl -k` 代替合法证书验证，也不能把现有 Matrix 会话临时改绑到测试子域。优先准备独立 TURN DNS/证书与受控的主域名 ACME DNS-01 签发方案；禁止复制源站私钥到共享节点。广州 Windows ECS 约 2 GiB 且与 Employ26 共享，正式切流前须测量容量和负载；GoDaddy 普通 A 记录不等于按地区智能选路。

源站有两套不同证书：公网宿主 Caddy 主域名证书至 2026-11-25，内层 Docker Nginx/现有 TURN 的 Certbot 主域名/admin/www lineage 至 2026-11-16。后者使用 standalone challenge，但源站 80/443 已由 Caddy 占用且无 pre/post hook，现有续期本身也有潜在端口冲突；切换主域名 A 后，两套证书的原验证路径还可能失效。广州 stock Caddy 没有 DNS provider 模块，不能假定可直接启用 DNS-01；边缘应在本机生成独立私钥并用经审查的自动 DNS-01 签发/续签方案，源站另保留可持续的 origin 域名或 DNS-01 证书，不复制源站私钥。2026-09-25 16:39 HKT 节点只读五次采样：总 1966 MiB RAM、可用 271–303 MiB；尚未测量目标负载，不能给出拍脑袋的固定扩容规格，也不适合直接承载所有长轮询/媒体请求。[阿里云备案说明](https://help.aliyun.com/zh/icp-filing/basic-icp-service/support/for-the-record-process-faq)要求中国内地服务器对外提供 Web 服务前核实 ICP 备案或新增接入；该域名当前备案状态尚未查证，不作已备案假设。

## 验收和回退

- 试点：权威 DNS 正确；新站点证书可信；公开两个端点各轮 200、其它路径 404；原 Employ26 站点/进程保持；MI 6 分段时延与超时率有实名信息之外的原始数值证据。
- 完整上线：直连与边缘来源 IP 语义一致，伪造 XFF 无效；验证码不会被代理自动重放；Matrix/E2EE、长轮询、媒体、通话 TURN 真实验收。保留源站与 DNS 回退，观察 TTL 600 秒传播。
- Caddy 任一步失败先恢复备份并重新 validate/reload；主域名未切流前，移除试点站点即回退。主域名若后续切流，按冻结旧 DNS 与 Caddy/源站配置顺序回退，保留 TURN 可用性。

**当前执行范围：** 用户新记录和“继续测试，并且增加该节点”授权阶段 1 试点。阶段 2 涉及认证限流、TURN 与主域名生产切换，须以其独立测试/审查结果决定切换时机。
