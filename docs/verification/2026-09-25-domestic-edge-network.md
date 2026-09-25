# 广州阿里云节点公开 HTTPS 试点验证（2026-09-25）

## 范围与现状

用户指定 `Administrator@8.163.93.151:22` 阿里云节点、确认可操作 GoDaddy DNS，并新增 `edge-cn-probe.liuhetong888.com` A 记录。当前仅将该独立测试域名接入节点；正式 `liuhetong888.com` DNS、Business/Matrix 客户端配置、TURN URI、源站 Nginx 与生产 API 镜像均未切换。MI 6 使用固定签名 Debug 2177，尚无真实账号登录、验证码送达或会话打开验收。

## 节点接入与保护

- 节点为广州 Windows Server 2019；80/443 上已有 Employ26 Caddy 2.11.4。试点对原 22 行配置做 ACL 保留备份，只追加独立站点，候选文件 SHA256 `a20ca505fb3fe6928be8b83d1ce609be378049312ff88ddcd4e12ba8185200da`。上线前 `caddy validate`，上线后核对运行配置；门禁任一步失败自动还原并重新加载。
- 新站点只代理 `GET /api/v1/health/ready` 与 `GET /_matrix/client/versions`；登录、POST、管理路径与其他路径返回 404。到源站使用固定地址、真实生产域名的 HTTPS SNI/Host 和证书校验；不缓存、不重试、不透传 Authorization/Cookie。公网试点证书 SAN 与严格 TLS 验证通过。
- 原 Employ26 IP HTTP 308 行为保持。原 IP HTTPS 握手在试点前后均失败；这项既存行为不能算已通过。试点未修改 Employ26 原站点块，也未重启原业务服务。
- 发布门禁 `activate-and-verify.ps1` 退出 0；[部署匿名结果](artifacts/2026-09-25/domestic-edge-network/edge-probe-20260925T0807202244330Z.json) SHA256 `0217b545be3d110a8591dbf8d7c35dc226a66e0a96e7a2c9cad112333a16d83c`。MI 6 两条公开路径各返回 200，非公开路径拒绝，工作站证书与 SAN 验证通过。
- 远端激活时实际执行的脚本原版保留在[本地原始产物](artifacts/2026-09-25/domestic-edge-network/stage_caddy_probe.py)，SHA256 `839f43bbbc9ee8230b2dccf65aed1d9ecc0b834cc4ce2f1df5d4aefcbeb2bd3a9`。独立安全复核发现其回退重试只检查磁盘配置，可能把运行配置未回退误报成功；[受约束部署/回退脚本](../../scripts/edge/starchat_public_probe.py)现补运行配置核对，SHA256 `d8c637b5eeddcfe122aa3c21b70e9748b4aa1c431913dd62c13cbb24651a30a5`。三项回退测试先 3 失败、修复后 3 通过（退出 0）；修正未重新激活试点或修改当前服务器。重跑及回退步骤见[运行手册](../runbooks/domestic-edge-probe.md)。

## MI 6 同窗口对照

2026-09-25 16:18–16:22 HKT，在已连接的 MI 6 上按每轮“源站 Business、边缘 Business、源站 Matrix、边缘 Matrix”顺序执行 10 轮。使用设备 `curl -q --noproxy '*'`，没有 `-k`；连接上限 10 秒、请求上限 12 秒。只保存路径类别、路由类别、HTTP/退出码、目标地址是否符合预期，以及 curl 实测 DNS/建连/TLS/首字节/总耗时；不保存目标 IP、完整 URL、响应体或身份数据。[40 条匿名原始记录](artifacts/2026-09-25/domestic-edge-network/paired-public-20260925T0821569800587Z.json) SHA256 `08a42acf5bd367bcdb0efea349b401190cf25964933329d5415c91837053ebe7`。

| 公开端点 | 直连源站 | 经广州节点 | 边缘成功请求 P50 / P95 / MAX |
| --- | ---: | ---: | ---: |
| Business ready | 4/10 为 200；6/10 超时 | 10/10 为 200 | 98.7 / 123.9 / 123.9 ms |
| Matrix versions | 4/10 为 200；6/10 超时 | 10/10 为 200 | 99.1 / 341.9 / 341.9 ms |

直连成功的 4 次 Business 总耗时 145.2–3198.3 ms，Matrix 为 130.8–10144.3 ms；失败均为 curl 28 超时。所有成功响应的目标地址均符合对应源站或边缘预期。curl 时间戳是累计值，不能把 `time_connect`、`time_appconnect`、`time_starttransfer` 当作独立阶段相加；超时样本缺失的阶段保持空值。

这组小样本明确显示 **MI 6 到当前源站的公开 HTTPS 链路有严重间歇性超时，而经广州节点访问相同上游路径在同一窗口稳定**。它不能证明故障位于哪一家运营商设备，也不能证明验证码、登录、Matrix 长轮询、加密媒体或 WebRTC 已修复。

16:52 HKT 再从 MI 6 严格 TLS、禁代理单次探测，Business ready 200/737.0 ms、Matrix versions 200/232.3 ms，目标地址均为预期边缘；这是后续存活检查，不并入上述 10 轮分位数。主域名仍解析至源站。

## 生产边界与下一门禁

- 复查时测试子域名 A 仍指广州节点，主域名 A 仍指原站，两者 TTL 均为 600 秒。生产 Business API 镜像 `sha256:25954c6a…` healthy/零重启。
- 生产 TURN UDP/TCP/TLS 使用主域名 3478/5349。直接把主域名 A 改到只承载 80/443 的广州节点会让现有 TURN 连接错误落到该节点，破坏通话。须先独立 TURN 域名、证书/续期、旧 URI 过渡和真实 relay 验收。
- 实际代理链是广州 Caddy → 源站宿主 Caddy → Docker Nginx → Uvicorn。现有源站 Caddy/Nginx 尚未构成仅信任上一跳的真实客户端 IP 链；直接放行登录/验证码会把客户端限流合并。此项是受保护的认证限流变更，需 ADR、失败测试、领域及质量/安全复核。边缘须清理传入的转发头且不得重放非幂等请求。
- 源站有两套不同证书：公网宿主 Caddy 的主域名证书至 2026-11-25；loopback Docker Nginx/现有 TURN 使用的 Certbot 主域名/admin/www lineage 至 2026-11-16，后者为 standalone challenge，且源站 80/443 当前被 Caddy 占用、无 pre/post hook。即使 DNS 不变，Certbot 下次真正续期也有端口冲突风险；若主域名 DNS 切到广州，两套源站证书的原 HTTP/TLS 验证路径还可能失效。广州 stock Caddy 2.11.4 没有 DNS provider 插件，且当前只有测试子域证书。须先有边缘和源站合法、可持续续期的方案，不能关闭广州→源站的 TLS 校验或复制源站私钥到共享节点。源站 Caddy→loopback 9443 的既有 `tls_insecure_skip_verify` 属内部链路，不得延伸到公网代理。
- 广州节点共 1966 MiB RAM。2026-09-25 16:39:00–16:39:12 HKT 通过 Windows `GlobalMemoryStatusEx` 五次只读采样，可用内存依次为 303/286/271/277/277 MiB（负载 84–86%）；2 秒 CPU 样本约 5.9%、磁盘余 15.88 GiB。它还与 Employ26 共用 80/443。不能仅据空载 CPU 或公开 GET 推算所需内存；须先提供容量余量并以代表性 Matrix 长轮询、媒体和认证并发测量新增峰值，再验证同域名 HTTPS、E2EE 会话、媒体大文件与流式传输、`/ios-call/`、资金 API、管理员拒绝和回退。现有试点只允许两个公开 GET，不承载真实用户业务。

当前可执行回退为还原冻结的原 Caddy 配置并 reload，移除测试 A 记录；正式主域名及源站配置无需回退。完整接入计划见[分阶段计划](../superpowers/plans/2026-09-25-domestic-edge-network.md)及[任务台账](../workflow/tasks/2026-09-25-domestic-edge-network.md)。
