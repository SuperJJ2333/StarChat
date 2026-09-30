# 新加坡边缘节点（边缘及TURN已上线）

**2026-09-27用户已明确授权部署边缘/TURN与S3**，按[部署计划](../superpowers/plans/2026-09-27-edge-s3-deployment.md)
和[任务台账](../workflow/tasks/2026-09-27-edge-s3-deployment.md)执行。EIP18.143.207.225/DNS、IAM和秘密已验证。
边缘nginx及固定coturn4.13.1已上线，实际公网UDP/TCP双向ChannelData、鉴权/私网拒绝及配额通过；
香港18:43追加SG两个TURN候选，原HK三个候选保留。新EIP定向TLS JSON健康200/403/404再次通过。
以下9月26日示例为设计历史，不能直接执行其中将静态密钥放argv的Compose。

实施采用protected0600文件挂载、hostnetwork、coturn自身匿名卷用tmpfs覆盖、仅NET_BIND_SERVICE必要
能力与固定digest；nginx1.27.5-alpine静态编译stream模块，不load不存在的so。实际候选和SHA以本批
验证报告为准；未知SNI拒绝，443定向测试，正常API仍香港，先不开放80/5349。

实际TURN镜像为`coturn/coturn:4.13.1-r0-alpine@sha256:e7320e6773fadb54e42ee485f7d8b3e6a000f4417e3acee98e1f34884e1b1f06`。
external-ip只写公网单值`18.143.207.225`，不要使用会隐式白名单私网地址的公网/私网二元形式；
裸`denied-peer-ip=::`会被该实现作为通配，不能替代IPv6拒绝清单。旧镜像及私有配置留作回退。
本批验证IPv4中继；没有宣称原生IPv6中继或生产真机通话已验收。

2026-09-26 已批准的[选址观测设计](../superpowers/specs/2026-09-26-regional-measurement-design.md)
当时只授权测量与文档纠错；本轮已有上述部署授权，但不包括正常API DNS切流或主区选择。暂无独立地区测点；真实用户新口径
需下一客户端更新后确认到达，再观察 7–14 天。本轮不能给出两地主区胜出结论。

当前执行配置见 [独立Compose](../../infra/compose/docker-compose.singapore-edge.yml)、
[nginx](../../infra/edge/nginx-edge.conf)、[TURN模板](../../infra/edge/turnserver.conf.template)与
[受保护渲染器](../../infra/edge/render_turn_config.py)。回退时仅停止本批两个具名容器；
先从香港模板移除SG TURN候选，等分配耗尽再停止TURN，不删除香港服务或本地媒体。

## 1. 定位与红线

- **无状态接入边缘**：新加坡节点（AWS ap-southeast-1，`ec2-user@18.143.207.225`，经 jumper 访问）
  只运行 nginx（L4 SNI 透传）与 coturn（通话中继）。**不部署**数据库、Synapse、business-api、
  bot、sygnal、element-web 或任何业务服务。
- **单一权威数据源**：业务数据（账本/钱包/身份）与 Matrix 数据的权威副本只在香港主站
  （207.56.8.8）。跨区域双写违反账本 append-only/幂等/Outbox 约束，属受保护变更，本方案不触碰。
- **节点上出现任何 `data/` 持久卷即视为违规部署**。原8G规划已扩为40GiB；磁盘只承载 OS、容器镜像与有上限的日志。
- 香港网关 nginx 里的安全路由（`/_matrix/client/.../login` 重写为业务 broker、`register/refresh/sso`
  一律 403、`/_synapse/admin` 404、push 按 provider 分流）是安全边界。本草案选择 **L4 SNI 透传**，
  使TLS终止、证书与HTTP路由仍归香港，新加坡只转发字节，减少边缘证书与HTTP策略管理。
  L7统一透明转发也可以保留单一香港网关规则；只有新增独立路由、授权或重写策略时，才须评审
  两层策略的一致性与绕过风险，不能把所有L7方案都等同于复制安全规则。
- 香港入口不能仅按仓库 nginx 模板推断：[2026-09-23 架构调查](../verification/2026-09-23-network-architecture.md)
  曾记录公网 443 为 Caddy 终止 TLS，再转发到 9443 nginx。这是历史证据；部署前必须只读核对
  当次 Caddy/nginx 监听、TLS 终止、HTTP 重定向及可信代理链路，不能假定公网 443 直接是 nginx。

## 2. 节点与访问信息

| 项 | 值 |
| --- | --- |
| 公网 IP | `18.143.207.225`（ap-southeast-1固定EIP，旧13.229地址仅作历史主机密钥身份） |
| 访问 | `ssh -J jumper -o HostKeyAlias=13.229.60.153 -i ~/.ssh/tee_13153299.pem ec2-user@18.143.207.225`（默认22端口，保留原可信主机密钥） |
| 密钥管理 | `.pem` 仅存本机用户目录，**不入仓库**；首连记录并核对主机指纹 |
| 平台防火墙 | AWS Security Group（区别于香港托管商安全组的既有教训，见 [turn.md](turn.md) §2） |

## 3. 磁盘预算（8G 根卷）

**2026-09-27现场更新**：角色绑定并完成目标卷快照后，14:23在线扩展分区/XFS，14:27复核根FS
约39.93GiB、可用38.07GiB；未重启、启动分区不变。主机c5.xlarge/4CPU/约7.50GiB；
下表8G预算为历史草案，不是当前Linux容量或边缘部署完成证明。
见[交接核验](../verification/2026-09-27-singapore-node-readiness.md)。具体边缘部署仍待独立门禁与批准。

8GB 是存储规格，不代表 RAM。下表是待核验预算，不能证明边缘容量，更不能据此配置完整主站。
尚需核对实际根卷可用空间、CPU、RAM、网络/EBS 性能、并发 TURN 和镜像解压/升级峰值占用。

| 占用 | 预算 |
| --- | --- |
| OS（Amazon Linux 2023 最小集） | ~2.0–2.5G |
| Docker 引擎 | ~0.5G |
| 镜像（nginx:1.27-alpine + coturn 4.6.3-r3） | < 0.5G（按 digest 固定） |
| 容器日志（json-file max-size=10m × 3 份 × 2 服务） | < 0.1G |
| journald（SystemMaxUse=200M） | 0.2G |
| **剩余余量** | **估算 > 4G，须以实际读回与升级峰值核验（禁止挪作数据用途）** |

日志上限仅在 nginx/coturn 全部日志输出 stdout/stderr 且实际容器启用轮转时成立；自定义文件日志
不受 Docker json-file 限制。发布需验证无增长中的文件日志、journald 的实际配额，并设置磁盘余量告警。

系统调优（边缘角色特有）：

```
# TURN 中继端口段不能落入内核临时端口范围（与香港同规则）
net.ipv4.ip_local_port_range = 1024 49159
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_udp_timeout_stream = 180
```

## 4. Compose 清单（草案文件：批准后物化为 `infra/compose/docker-compose.singapore-edge.yml`）

```yaml
# 新加坡边缘节点 —— 无状态接入边缘（nginx L4 透传 + coturn）
# 红线：本文件不得加入任何数据卷、数据库或业务服务；见 docs/runbooks/singapore-edge-node.md
services:
  edge-nginx:
    image: "${EDGE_NGINX_IMAGE:?EDGE_NGINX_IMAGE is required}"   # 例 nginx:1.27-alpine，部署时按 digest 固定
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ../edge/nginx-edge.conf:/etc/nginx/nginx.conf:ro
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
    healthcheck:
      test: ["CMD-SHELL", "wget -q -T 2 -O /dev/null http://127.0.0.1:8080/health/live || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3

  edge-coturn:
    image: "${EDGE_COTURN_IMAGE:?EDGE_COTURN_IMAGE is required}" # 例 coturn/coturn:4.6.3-r3
    restart: unless-stopped
    command:
      - "--no-cli"
      - "--log-file=stdout"
      - "--fingerprint"
      - "--use-auth-secret"
      # 与香港 .env 的 TURN_SHARED_SECRET 完全一致：同一 REST 凭据在两地均通过认证
      - "--static-auth-secret=${TURN_SHARED_SECRET:?TURN_SHARED_SECRET is required}"
      - "--realm=${EDGE_TURN_REALM:?EDGE_TURN_REALM is required}"        # 与香港生产 realm 一致
      - "--external-ip=${EDGE_TURN_EXTERNAL_IP:?EDGE_TURN_EXTERNAL_IP is required}"  # 13.229.60.153
      - "--listening-port=3478"
      - "--min-port=49160"
      - "--max-port=49200"
    ports:
      - "3478:3478/udp"
      - "3478:3478/tcp"
      - "49160-49200:49160-49200/udp"
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
```

`.env.edge` 模板（值只在服务器侧，不入仓库）：

```
EDGE_NGINX_IMAGE=nginx:1.27-alpine@sha256:<部署时固定>
EDGE_COTURN_IMAGE=coturn/coturn:4.6.3-r3@sha256:<部署时固定>
TURN_SHARED_SECRET=<与香港一致的 64 位密钥，经既有渠道取用>
EDGE_TURN_REALM=<与香港生产 MATRIX_SERVER_NAME/realm 一致>
EDGE_TURN_EXTERNAL_IP=13.229.60.153
```

## 5. nginx 边缘配置（草案：`infra/edge/nginx-edge.conf`）

```nginx
# 新加坡边缘 nginx —— 纯 L4 SNI 透传。
# 不持有任何证书；不做任何 HTTP 层路由/改写；TLS 终止与全部安全路由在香港网关。
# 官方 nginx 镜像需含 stream_ssl_preread 模块：部署前以 `docker run --rm <镜像> nginx -V`
# 核对 configure args；动态模块须按该镜像实际路径 load_module。完整候选配置 nginx -t
# 必须成功；仅 configure args 中出现模块名不算通过（发布门禁，不得跳过）。

user nginx;
worker_processes auto;
error_log /dev/stderr warn;
pid /var/run/nginx.pid;

events { worker_connections 4096; }

http {
    access_log off;
    server {
        listen 127.0.0.1:8080;
        location = /health/live { return 200 'alive\n'; }
        location / { return 404; }
    }
}

stream {
    log_format edge '$remote_addr [$time_local] sni=$ssl_preread_server_name '
                    'received=$bytes_received sent=$bytes_sent status=$status';
    access_log /dev/stdout edge;

    # 香港主站固定公网 IP；Phase 1 仅授权定向测试，不作为正式用户导流配置。
    upstream hk_tls  { server 207.56.8.8:443; }
    upstream hk_http { server 207.56.8.8:80;  }

    server {
        listen 443;
        ssl_preread on;
        proxy_pass hk_tls;
        # PROXY protocol 上报真实客户端 IP 属 phase 2（需香港同步新增带
        # proxy_protocol 的独立监听端口，见 §7），phase 1 定向测试回源看见边缘 IP。
        # 源 IP 信任/限流门禁通过前，不得将正常 API/同步用户导入此链路。
        # proxy_protocol on;
    }

    server {
        listen 80;
        proxy_pass hk_http;
    }
}
```

**本草案选择L4的理由**：L4保持香港现有HTTP安全路由，边缘无证书、无业务状态。L7透明回源
并不必然复制login-broker、403/404与push规则，但仍需管理证书、可信代理头、重定向与请求体
上限；若新增独立HTTP策略，必须证明不会绕过香港安全边界。仓库nginx `client_max_body_size`
为100m，Synapse模板 `max_upload_size` 为50M，两者不是同一上限，当次生产值须读回。
正式导流仍需第7节源IP/实际TLS入口门禁，不能把“透传”理解成香港永远无需改配置。

8080 仅为容器 loopback 的本机存活检查，不证明香港回源或 TURN 可用。回源检查须使用正确域名/SNI、
保留证书验证、不跟随重定向，并验证 `/api/v1/health/ready` 的200及JSON `ok=true`、
`database=ready`（没有 `status` 字段）；80 的香港重定向
不能充当本机 healthcheck。HTTP/TURN 验收分别记录，禁止用网站 HTML 200 代替 API 健康。

## 6. TURN 与 homeserver 联动（唯一的香港侧改动）

- 两地 coturn 使用**同一** `TURN_SHARED_SECRET`（REST 认证凭据通用）；realm 取值与香港生产一致。
- 香港 homeserver 的 `turn_uris` 追加新加坡条目（客户端从 `/voip/turnServer` 获取全部 URI，
  作为 ICE 候选；ICE 按优先级、连通性与提名策略选择，不保证选到最低 RTT，也不保证香港用户
  无性能回归；需对照真实通话的选中候选、RTT、丢包和建立时间）：
  - `turn:sg.liuhetong888.com:3478?transport=udp`
  - `turn:sg.liuhetong888.com:3478?transport=tcp`
- `turn_uris` 由 `infra/render_config.py` 渲染 homeserver.yaml：改动必须走模板并 `--check` 无漂移，
  按香港发布流程执行（改前备份 homeserver.yaml）。
- EDGE TURN TLS（`turns:...5349`）为**可选 phase 2**：需 `sg.liuhetong888.com` 的证书签发与 coturn
  TLS 挂载（香港已有 root:65534 权限教训，见 [turn.md](turn.md) §2026-09-05）。phase 1 先 3478
  udp/tcp 上线。
- 新增 DNS 记录：`sg.liuhetong888.com A 13.229.60.153`（仅 TURN 用途；不改变 API/web 域名解析）。

## 7. 分期与 DNS 路由

| 阶段 | 内容 | DNS 变更 | 香港侧改动 |
| --- | --- | --- | --- |
| **Phase 1（草案范围）** | SG TURN 候选；L4 只作准备/定向测试 | 仅新增 `sg.liuhetong888.com` | 模板追加 `turn_uris` 并验证，不改 API 导流 |
| Phase 2（另行批准） | 亚洲/东南亚用户 API/同步流量经边缘 | GeoDNS 按地区解析 | 核对实际 TLS 入口后新增可信源 IP 专用回源路径，仅放行边缘 IP |
| 不做 | 双区域独立数据库/独立媒体副本 | — | — |

Phase 1 不改变 API/web DNS，正常 API/同步用户流量仍直达香港；不得把启动 L4 透传说成已获得
亚洲 API 加速。新加坡 TURN 也只是潜在收益，必须实测；TURN 是连接兜底，不是天然加速器。

Phase 2 切流前硬门禁：核对边缘 → 实际香港 TLS 入口（含 Caddy 如仍在用）→ nginx →
ASGI/Synapse 的可信源 IP 链路。可评审边缘 `proxy_protocol on` 和专用回源端口；若由 nginx
直接接 TLS，可使用 `listen 4443 ssl proxy_protocol`、严格 `set_real_ip_from` 与
`real_ip_header proxy_protocol`，但不是当前 Caddy 链路的现成配置。原 443 直连路径保留。
不得接受任意客户端伪造的 PROXY/X-Forwarded-For；回源端口和代理信任仅允许已核实的来源。
验收需证明两不同客户端的 IP 限流桶、审计源 IP 独立，伪造头无效，直连也不回归。源 IP 丢失
影响发码、登录、broker 与诊断 IP 限流及审计，不能只当成日志显示问题；门禁未过不得导流。

## 8. AWS 安全组 / 防火墙清单

| 端口 | 协议 | 来源 | 用途 |
| --- | --- | --- | --- |
| 80 | tcp | Phase 1 仅授权测试来源；正式开放另行评审 | HTTP 透传 |
| 443 | tcp | Phase 1 仅授权测试来源；正式开放另行评审 | TLS 透传 |
| 3478 | tcp+udp | 0.0.0.0/0 | TURN |
| 49160–49200 | udp | 0.0.0.0/0 | TURN 中继段 |
| 22 | tcp | jumper 仅 | 管理 |
| （可选 phase 2）5349 | tcp+udp | 0.0.0.0/0 | TURN TLS |
| （可选 phase 2）4443 | tcp | 207.56.8.8 反向不适用；此条为香港 ufw 放行边缘 IP | proxy_protocol 回源 |

安全组与实际主机防火墙双层均须核验。香港历史 5349 排查后来证实为 coturn 私钥读取权限问题，
见 [turn.md](turn.md) 顶部 2026-09-05 修正；不能沿用旧“只放一层”的根因判断。

## 9. 发布步骤（批准后，按 admin-production-workflow 执行）

1. 建[任务记录](../workflow/task-template.md)：文件所有权 = 本文档 + `infra/compose/`、`infra/edge/`
   新增文件 + 香港 `render_config` 模板；记录本草案批准证据。
2. 物化第 4–6 节文件；镜像 `nginx -V` 核对模块并用实际候选配置 `nginx -t`；镜像按 digest 固定。
   Compose 相对挂载按 `infra/compose/` 目录解析；核对实际挂载源与日志轮转，无镜像内文件日志漏项。
3. AWS 安全组 + 主机 ufw + sysctl 落地；`ss -lun` 核对 3478/49160-49200 监听。
4. 边缘容器启动；分别验证本机 healthcheck 与 `curl --fail --resolve liuhetong888.com:443:127.0.0.1
   https://liuhetong888.com/api/v1/health/ready` 的200，并单独校验JSON `ok=true`、`database=ready`，
   再经 jumper SOCKS loopback
   公网复测（保留 SNI/证书校验、不跟随重定向；代理路径不算真实运营商测点）。
5. TURN 验收：`turnutils_uclient -e <SG_IP> -u <expiry> -w <hmac> 13.229.60.153` 强制中继；真机
   通话看 `chatflow/callquality` 的 `turn=used`（日志口径见 [turn.md](turn.md) §3）。
6. 香港 `turn_uris` 追加经 render_config 模板发布（香港侧独立发布记录 + homeserver.yaml 备份）。
7. 证据归档 `docs/verification/artifacts/<日期>/singapore-edge/`，验收台账按需求 ID 记录。

## 10. 回退

- TURN 先从香港 `turn_uris` 移除 SG 条目，保留香港候选；客户端当前源码最多缓存五分钟，
  需验证刷新窗口与新通话回退。既有 SG allocation 不会因列表/DNS 变更自动无损迁到香港；
  停止容器会中断仍使用 SG 的通话，恢复可能需要 ICE restart/重新建立通话，并须真机验证。
  正常回退应先停止新分配并排空既有 allocation，确认无人使用后再停止容器/移除 DNS；
  紧急下线需明确现通话中断风险，不能承诺无损或零感知。
- L4 透传层：GeoDNS 未启用且没有正常 API 用户导流时，下线不改变正常 API 路径，但会影响
  定向测试连接；TURN 用户影响按上一条处理。Phase 2 的 DNS 缓存、长连接及回源回退另行评审。

## 11. 明确不在本方案范围

- 任何数据库、媒体、业务服务在新加坡落地（如需完整区域站或 RDS，另行立项 + ADR）。
- 媒体字节 S3 化（独立提案见 [ADR-0086](../adr/0086-media-storage-s3-backend.md)）。
- CDN、GeoDNS 生产化、QUIC/UDP 443 透传。

## 2026-09-27实际媒体运行配置与回退

业务S3主写已经上线（API固定1aa6c222、worker0e011134），Synapse主进程及sync固定99643e45且两个生命周期provider同步S3写。实际源配置、SHA、备份和恢复记录留在香港release的root0700/private600目录；维护凭据和AWS SDK共享文件不得复制进仓库或发到聊天。

- 普通Docker重启沿用当前容器配置。后续重建/新版本必须先读取各服务实际Compose标签及image，依据当前1aa6/0e011/996做最小增量；本批保留了并行获批PHONE-only修复，不能改回旧55ac/e880候选。
- 业务回退为同镜像`local_s3_read`：本地写入、本地优先+S3回读；现有新S3-only对象继续可用。冻结before/candidate为服务器`private/business-s3-write-v3/`，完整摘要与运行漂移检查先于任何恢复。不能切回local-only旧像或删除SDK挂载。
- Synapse回退必须继续使用996与生命周期provider，只将`write_enabled`设false，同时保留S3回读、永久fence与授权模块；两个进程按冻结兼容配置一并重建。先核对当前runtime/template/env SHA再恢复，遇并行漂移不可覆盖。`publish-synapse-s3-release.py`不提供发布后通用`--rollback`参数，不重复其已结束的publication journal。
- 全局`render_config --check`仍有既有modules/nginx模板漂移；禁止用整套重新生成覆盖香港安全规则。正常API入口/业务权威和数据库仍香港。仅以本批精确provider/TURN增量验证为证据。
- 本轮所有本地媒体字节保留。容量/平台GC统计和SDK错误由新systemd timer每五分钟读取，root私有本地告警；不做GC执行、外部消息推送或自动删本地。当前探测镜像55ac是受审的只读LIST/SQL采样容器，区别于实际1aa6 API。

执行身份、存量迁移和实际接口验收见[部署验证](../verification/2026-09-27-edge-s3-deployment.md)。现场对象路径/大小覆盖只能证明检查快照；真实附件/ICE体验和主区选择仍需更新客户端的使用日志及7–14天覆盖数据。

21:21当次Synapse有限回填已完成，随后DB权威快照2923有效对象全匹配S3路径/大小，业务切写后108对象复核通过。全部本地字节保留，旧游标和SDK挂载不删除；不得再次启动已完成loop或因S3桶存在便清空源卷。正常重建仍遵循上面的实际镜像/Compose规则。最终四服务及SG两容器健康、监控OK，整体ATTENTION来自已有topic未注册consumer持续产生新Outbox DEAD（21:31快照431），没有本批媒体处理器失败证据；不自动重放未知/金融事件或跳过错误标记。全renderer漂移与真实客户端体验缺口继续保留。
