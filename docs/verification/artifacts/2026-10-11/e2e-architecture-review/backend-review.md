# 后端网络、存储与可观测性只读评审

日期：2026-10-11（Asia/Hong_Kong）。只读代码、配置模板、既有脱敏证据；未连接生产、未读取 .env/秘密/用户正文、未修改产品或生产。唯一写入为本目录 `backend-*` 证据。没有 `.codegraph/`，按规则直接检索。相关源码不等于当前生产镜像；生产配置一致性未在本子任务验证。

证据分类：**代码证实** = 当前工作区实现；**合成复现** = 当前真实路由、替换外部依赖，不是线上测量；**现场快照** = 主审在09:18:59+08只读取得；**历史观察** = 明确日期与测试条件；**待验证风险** = 由实现推导的失败情景，尚未复现为线上事故。本范围未发现足以认定现行 P0 故障的证据。P1/P2 是建议处理优先级，不代表所有条目均已在线发生。

## 已有正面能力

- Matrix/Synapse 与业务数据库分离：`docker-compose.yml:2`、`:185`；Synapse主进程与同步worker均挂载持久目录，PostgreSQL承担消息权威，业务Outbox在业务PostgreSQL中事务入队（`services/business-api/app/core/outbox.py:51-79`）。Matrix Redis在`:45-48`关闭持久化，本身不是消息存储；不能由此推出聊天消息会因Redis重启永久丢失。业务Redis启用AOF（`:200-205`）。
- Synapse同步独立worker、Redis复制协调、main/worker连接池上限30/15（`infra/synapse/homeserver.yaml.template:22-36`、`infra/synapse/worker-sync.yaml.template:19-28`）。网关动态Docker DNS解析和精确sync/events分流已存在（`infra/nginx/nginx.conf.template:7-21`、`:126-134`），不是全部流量挤在同一个Synapse进程。
- TLS1.2/1.3、隐藏Synapse admin、禁公有注册、登录broker、iOS-call限流、固定push上游、loopback回源边界已实现（nginx模板`:68-98`、`:137-168`；`docker-compose.production.yml:57-61`）。这些是局部边界，不等于整个链路容灾/容量已验收。
- Outbox有`SKIP LOCKED`、五分钟过期租约、有界指数退避、DEAD保留、内部发布耐久幂等回执；9/28历史观察6045.611秒374条全部发布且回执匹配，历史死信保留（`docs/runbooks/outbox-internal-publication.md:7-46`）。不得再次称“没有Outbox消费者”或将历史死信总数当新故障。
- 媒体已有S3后端、checksum/长度/最大对象限制、仅确定404才本地回读、生命周期fence与GC、权限守卫、统计；9/27已部署S3主写属于历史证据（`docs/adr/0086-media-storage-s3-backend.md:3-8`），本次实时容器镜像快照不单独证明当前配置仍完全相同。旧架构审计中的“全部媒体单盘/无指标”已过时。
- 已有API/SQL/媒体滚动指标、受保护性能端点、客户端诊断与请求UUID关联、分层错误类别、诊断队列/采样限额和日志轮转要求。优点是闭合字段、不记录内容或凭据；缺口是覆盖与持续性，见B7/B8。

## B1 — P1：异步媒体路由执行同步存储IO，阻塞同进程事件循环

**状态：代码证实 + 合成复现；不是已证明的线上故障根因。**

- 现象/范围：媒体读取慢时，同API进程上无关异步请求、定时回调可能一起延迟；并发大文件另有整对象内存叠加风险。平台签名媒体和头像读取均有此形态；不直接归因到Synapse聊天发送。
- 触发链：`services/business-api/app/api/media_platform.py:539-555` 的 `async read_signed_content` 直接调用同步 `service.read_via_signed_token`；`modules/media/service.py:198-206`、`:367-418` → `modules/media/repository.py:408-411` → `integrations/media_blob_storage.py:96-122`，boto3同步GET/正文循环读取后才返回完整bytes。SDK timeout/retry存在（`:77-79`），但没有把IO移出事件循环。头像同形态见 `api/profile.py:272-280`、`integrations/private_storage.py:98-121`。
- 本次复现：真实router创建，存储delegate替换为250ms的合成同步等待；并列安排10ms loop timer。输出HTTP200，`timer_ran_before_response=false`，timer实际250.47ms。脚本/结果：[backend-media-event-loop-probe.py](backend-media-event-loop-probe.py)、[backend-media-event-loop-probe.txt](backend-media-event-loop-probe.txt)，退出0；含Python/OS/四源SHA。**无网络、无DB，不测试授权正确性；250ms是故意注入，不是线上S3延迟。**
- 根因：FastAPI异步route内同步调用，不会因为route写为async自动获得线程池调度；整个对象装入BytesIO，首字节必须等后端完整读取及校验。
- 优化：先将已同步的存储/DB调用放入有界执行池或同步route，设清楚总deadline/并发上限；再评估支持流式/Range/校验的对象读取协议。保留签名授权、撤权、完整性校验及错误分类，不能直接将私有桶公开或禁用checksum。
- 验证验收：同真实route+慢存储fixture，10ms心跳不随250ms存储等待延迟；并发下载时无关API p95/事件循环lag达到预先冻结目标；限制在途字节/RSS；完整回归404、超时、撤权、损坏、断连。生产候选须逐源SHA证明包含该修复，不能以本地测试代替上线确认。

## B2 — P1：核心服务与测试/其他项目同宿主且无容器资源上限

**状态：现场快照证实资源配置；资源争抢导致用户事故仍待验证。**

- 现象/范围：任一核心服务、测试恢复栈或其他项目突发占用，可争抢主业务CPU/内存/磁盘。快照共35个容器；8个核心服务与recovery-worker `memory_limit=0 cpu_quota=0`，见 [production-resource-snapshot.txt](production-resource-snapshot.txt):17-51、87-95。
- 现场边界：宿主7900MiB，available3784MiB，swap2043/2047MiB；PSI avg10/60/300=0，vmstat后4个1秒si/so=0，核心restart0/oomfalse（同文件:1-16、87-95）。**不能据swap存量直接认定当时在thrashing，更不能由此解释手机OOM。** 磁盘41%也不是磁盘当前已满。
- 触发/复现：在独立同规格环境增加S3大文件/初始sync/数据库负载，叠加演练栈，观察PSI、swap-in/out、IO延迟、RSS和业务p95；不应直接压生产。
- 根因/优化：失败域与容量预算未隔离。先建立每服务峰值/保留量，给演练与其他项目可控配额和生命周期，逐服务压测后设CPU/内存保护；不可凭瞬时RSS粗暴设低内存导致主动OOM。现场recovery-worker unhealthy属于恢复栈，不是线上Synapse worker故障；恢复栈可能承担受保护能力，必须核对归属/用途后再安排资源。
- 验收：忙时连续曲线和混合负载证明核心SLO；异常资源消耗不会拖垮核心业务；配额触发、回退及告警有演练证据。

## B3 — P1：同步worker独立了负载，但仍是单一同步入口

**状态：代码/模板证实；当前现场主worker健康，没有本次线上中断证据。**

- 现象/范围：单个sync-worker重启、故障或过载时，客户端可仍登录/调用业务API，但`/sync`、`/events`断续，产生“能登录但列表/收消息不更新”。
- 证据：nginx `synapse_sync_upstream`只有一个server（`infra/nginx/nginx.conf.template:14-17`），两类路由只发给该upstream（`:126-134`）；`docker-compose.yml:55-76`只定义一个worker，healthcheck只做存活检查，未实现自动切流。现场线上sync-worker健康（快照:21），unhealthy的是隔离recovery栈（:23）。
- 复现：隔离环境中仅停sync-worker，保持main/API健康；比较`/health`、业务ready与带测试token的sync错误/恢复时间，不读取真实用户消息。
- 优化：根据容量数据建设多个同步worker/受控滚动发布、健康感知路由；若设计main备用，需先证明main承载能力与故障风暴限制。不能仅复制容器就宣称HA，还要检查同机/Redis/DB故障域。
- 验收：滚动重建和一个worker失败期间，恢复时长及实际收到事件延迟达标；增量token续接、重试不丢不重、连接回收均有SDK证据。

## B4 — P1：边缘与S3提高了接入/字节存储能力，但权威业务仍是单源站故障域

**状态：代码证实拓扑 + 历史恢复观察；当前备份频率/覆盖/RPO/RTO未实时核查。**

- 现象/范围：香港源站/其PostgreSQL不可用时，新加坡边缘不能独立提供登录、消息权威或钱包业务；S3可访问也不能替代授权/元数据。S3独有新对象在S3不可达时也不能靠保留的旧本地卷自动恢复。
- 证据：`infra/edge/nginx-edge.conf:23-37`只有香港TLS upstream；`docs/runbooks/network-probes.md:45-49`明确新加坡边缘回源不构成主区容灾；`docker-compose.yml:2-16`、`:185-198`为单个持久化PG。S3单写/兼容回退限制见 `docs/adr/0086-media-storage-s3-backend.md:60-73`。
- 正面历史：9/27两个PG真实dump并隔离恢复，业务138表/schema0090、Synapse168表一致（`docs/workflow/tasks/2026-09-27-edge-s3-deployment.md:63`；`docs/verification/2026-09-27-edge-s3-deployment.md:90`）。存在恢复验证，不能说“没有备份”；但该快照不证明10/11最新数据、完整介质/配置/签名身份、持续备份或整站RTO。
- 优化：先冻结业务目标RPO/RTO、完整依赖/恢复顺序和异地可恢复清单，持续验证DB+对象+fence/墓碑+配置的同一恢复点；再根据目标决定备用数据库/故障域，不建议未经测量就迁区或双写金融权威。
- 验收：从最新独立备份重建隔离整栈，证明认证/消息/引用媒体可读、删除对象不复活、账本不重复写、Outbox能幂等恢复；记录真实数据截止点、丢失上界和恢复耗时，并演练源站断连、S3断连、DNS/TLS切换与回退。

## B5 — P1：现有HTTP容量PASS不等于首同步SLO，更不等于千人E2EE能力

**状态：历史实测缺口 + 当前负载脚本门禁证实；不能把历史机器成绩直接当生产容量。**

- 现象/范围：请求最终成功仍可能等待数十秒；冷/首次群同步和活跃消息扇出可能先损害体验。
- 证据：9/10实测200VU六轮PASS，但初始sync p95最高22.967s；500VU第一轮两路径FAIL，后续四轮PASS（`docs/verification/2026-09-10-media-capacity-runtime.md:19-38`）。测试是WSL4GiB/4vCPU、同机k6、每轮hold2min，且不发送/解密消息（`:40-47`）。当前 `scripts/loadtest/capacity.js:31-38`门禁有sync成功率、发送/入群耗时，却没有initial/incremental sync Trend的延迟阈值。
- 根因：性能验收口径缺少首同步/追赶SLO，测试层级尚未覆盖真实SDK密钥分享、千人成员解密和端侧UI。增量约30s是long-poll等待，不应当作消息送达延迟；旧500首次失败的唯一根因未证实。
- 优化/复现：独立同规格环境重跑冷热、重连风暴、200/500到目标人数、10-30min稳定混合负载；分开“空闲长轮询”和“有事件追赶”。先规定首同步/发送→对端显示及解密成功率SLO，再决定加worker/调DB。
- 验收：覆盖真实E2EE新老设备、突发消息/附件、成员变更和缺钥恢复，三次独立重复均达到事先冻结阈值；保留失败分母、k6/服务资源以及Android/iOS端侧数据。

## B6 — P2（容量上升前升P1）：Outbox持久化可靠，但共享串行执行链有跨topic队头阻塞风险

**状态：代码证实调度；未证明当前线上积压。**

- 现象/范围：慢邮件/S3清理/外部请求或维护任务会延迟其他发布任务，即便API事务已提交。不能将此解释为金融状态由消息决定，业务状态仍由事务权威产生。
- 证据：`services/business-worker/app/worker.py:101-129`逐一同步执行维护任务；`:149-185`维护→领取一批→同步逐条handler→heartbeat。默认limit50（`:149`、`:198`），整批同一时刻领取五分钟租约（`services/business-api/app/core/outbox.py:87`、`:118-136`），本类未续租。多消费者情况下，整批耗时超5min可使尚未轮到的条目被回收；不能由此直接声称重复入账，幂等消费者仍是保护层。储备监测已有独立runner（`services/business-worker/app/main.py:161-165`），不能说所有长期任务均无隔离。
- 复现：隔离PG与合成慢handler，注入外部超时/50条批次，再启动第二消费者；测各topic oldest age、成功时间、租约冲突、重复投递与回执。故障注入不触发真实资金命令。
- 优化：按对外IO和时效分配有界并发/topic工作池；缩小批次或安全续租；保留幂等、稳定worker身份、死信、回执与审计。金融事件不直接盲目重放。
- 验收：慢topic不会令关键topic超时；进程崩溃/ACK丢失/租约到期仍仅产生合法一次业务结果与一致回执；积压/超龄/DEAD有独立告警。

## B7 — P2：健康检查只证明局部存活，无法回答“用户能否真正聊天”

**状态：代码证实检查语义，不是健康接口bug。**

- 现象/范围：业务ready=200时，Matrix同步、S3、推送或Outbox可能已退化；当前API健康与用户可用性的证据等级不同。
- 证据：`services/business-api/app/api/health.py:25-39`只执行DB `SELECT 1`。Synapse main/worker healthcheck只GET各自`/health`（`docker-compose.yml:38-43`、`:71-76`）；Worker heartbeat只检查mtime<30sec（`:346`）。这适合局部liveness/readiness，不能给整体“消息正常”背书。
- 复现：隔离环境阻断S3或sync-worker，保持业务PG可用，业务ready依然可200；再由合成测试账号做完整业务/消息操作定位失败阶段。
- 优化：保留廉价存活探针，另设受控分层依赖健康与低频合成用户旅程；避免把所有依赖串在单个ready内而制造级联重启。指标覆盖认证、入房、事件提交、接收解密、媒体、推送唤醒、Outbox超龄。
- 验收：每一类故障注入均被正确分层告警，且不泄漏明文/密钥；恢复后用真实SDK确认用户旅程恢复，不只看HTTP200。

## B8 — P2：诊断已建设，但采样、进程窗口与链路覆盖不足以自动归因所有用户事故

**状态：代码/手册证实边界；未断言生产完全没有外部监控。**

- 现象/范围：短时异常可能在重启或队列上限后消失；多worker随机命中得到不同窗口，缺记录不能直接判为网络断开或服务未处理。客户端→业务API不能覆盖客户端→Matrix→对端解密的全旅程。
- 证据：`core/tracing.py:121-150`每进程256series、每series512样本，最近关联256条；`api/performance_diagnostics.py:95-124`仅当前worker快照。`core/database.py:26-28`SQL计时不含拿连接/读取结果，`:76-78`连接等待为None。`core/network_request_timeline.py:142-175`每worker队列1024、600条/分钟，丢弃计数显式存在；这是有意有界设计。网络摘要只覆盖primary_api/连接方式，不识别地区运营商，不覆盖Matrix、对端显示、媒体全链路、TURN（`docs/runbooks/network-probes.md:47`）。
- 优化：在现有安全字段基础上增加进程启动ID/采样分母/丢弃与队列lag，持续持久汇总可聚合直方图和版本身份；建立trace/request/operation的关系，不在服务端采集聊天明文或房间密钥。为Matrix发送→sync→本地解密/落库/显示建立端侧分段时间，不直接相减未校准墙钟。
- 验收：多worker与进程重启不混淆样本，丢样比例可计算；故障注入可区分DNS/TLS/HTTP、服务排队/SQL/对象存储、端侧处理；生产持续7-14天含忙时数据支撑区域和容量决策。不能以缺Prometheus/Grafana某个工具名直接判定架构差。

## 建议执行顺序与证据缺口

先B1最小修复及并发回归；并行补B2连续资源数据/B5明确SLO；接着按B3/B4做隔离故障恢复演练；B6以topic超龄及慢handler注入决定是否拆队列；B7/B8贯通采样与合成旅程。当前无生产写入授权，本报告不执行修复或切流。

缺口明确保留：工作区与当前镜像逐文件一致性；实时S3/边缘/DNS/备份有效配置；至少一个完整繁忙时段的PSI/IO/SQL池等待/重试与每topic延迟；最新全栈恢复RPO/RTO；真实1000成员E2EE、独立负载机和双端网络/推送/媒体旅程。09:18:59几秒资源快照及9/10、9/27历史测试不能填补这些缺口。

## 本次证据身份与检查

- 合成复现命令：`.venv/Scripts/python.exe docs/verification/artifacts/2026-10-11/e2e-architecture-review/backend-media-event-loop-probe.py`；Python3.12.10/Windows10，`PYTHONDONTWRITEBYTECODE=1`，09:23:09+08记录，exit0；不是产品测试全量通过。
- `services/business-api/app/api/media_platform.py` SHA256 `32cb48d0ef95873e2ecaa27cbe119b9f3f39d7b1529b55f043beb819276d680e`。
- `services/business-api/app/integrations/media_blob_storage.py` SHA256 `bcc07fbb962022769caa701bddada05f3119e4c4fefcc4603b1218760285ea1b`。
- `services/business-worker/app/worker.py` SHA256 `b89ae73864a5db25c0813736df3b89ee062192f34e1e3cca54a001a0796d6f71`。
- `infra/nginx/nginx.conf.template` SHA256 `3fc78220fc998a93aa11ab5565c4f27dce1454fb7e1e2eec0e4b7628cb234afb`。
- `docker-compose.yml` SHA256 `5c7abf110b4aa39c7d642a0ef5b0da618bbb1f70a95ccc37d250aaf0dd38ed7a`。
- 现场快照SHA256 `132fc1a5fe97fbb3010878f919f5a7e607ed6c04cbd763172b289a646c79a0da`，由主审负责采集。
- 未运行构建、全量测试、生产压测、故障注入或恢复；没有产品修改。精确总工时/工具时间拆分未逐阶段记录，不编造耗时；本子任务于09:23后整理报告，原始时间以工具和证据为准。

