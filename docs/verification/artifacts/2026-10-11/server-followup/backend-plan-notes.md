# 后端现场只读补查与最小修复任务

日期：2026-10-11；作者：backend_review；范围：业务 API、业务 worker、PostgreSQL、Outbox、选定 pusher 聚合；未实施修复或部署。

## 证据身份与执行边界

- 主采样 `backend-runtime.json`：UTC 02:00:19.902565—02:00:21.314266；细分采样 `backend-runtime-detail.json`：UTC 02:03:51.876355—02:03:53.647732（香港时间 +08:00）。相应 `.py` 为原始采集器，`.txt` 记录执行时间、退出码 0 与采集器 SHA。
- 经 `scripts/starchat-server.ps1`、既有 jumper 执行；Python 采集器在远端内存执行，没有写服务器文件。SQL 仅聚合，`BEGIN READ ONLY`、`statement_timeout=5s`、`lock_timeout=1s`、`ROLLBACK`；未执行 EXPLAIN ANALYZE。
- 只输出明确允许的配置项、文件 SHA、AST 调用结构、状态/大小/时延聚合。未输出 DSN、密码、token、账户/设备标识、钱包地址、原始日志、消息、附件、恢复密钥或数据库正文。日志截尾并设字节上限，没有把有界日志称为完整 24 小时。
- 本次不新增账号、不发送消息、不做生产压测，不改变生产数据、配置或服务状态。后续修复任务尚未执行。

## 现场结论

### 1. P1：媒体同步 I/O 风险已绑定当前运行实例，尚无真实 S3 延迟测量

业务 API 当前镜像 `sha256:58dca4884b89bc25839f9cfb652c67528f79473aca8ebcd79df2992f6509452f`，2026-10-05 启动；实际 import 根目录 `/opt/business-api/app`。允许列表配置显示 `BUSINESS_API_WORKERS=2`、`BUSINESS_MEDIA_BLOB_BACKEND=s3`、对象上限 67108864 字节。运行中的下列四文件 SHA 与本地合成复现所依赖源码逐一一致：

| 文件（相对于 services/business-api/app） | 当前运行 SHA256 |
| --- | --- |
| api/media_platform.py | 32cb48d0ef95873e2ecaa27cbe119b9f3f39d7b1529b55f043beb819276d680e |
| modules/media/service.py | 0a72ac4941f83a46598a18d5b6ec7a8e9946cf92029966e020bfb7fd09ff2b31 |
| modules/media/repository.py | f0ea1ec9fb46ae9f9271b1f31721e8e0c45a460d380f78a53b83440b0be8fa96 |
| integrations/media_blob_storage.py | bcc07fbb962022769caa701bddada05f3119e4c4fefcc4603b1218760285ea1b |

代码链：`api/media_platform.py:540,553` 的 async signed-content handler 直接调用同步 service → `modules/media/service.py:367` → `modules/media/repository.py:408` → `integrations/media_blob_storage.py:96` 同步 S3 下载、整对象缓冲。运行 AST 亦确认 async/direct-sync-call。已有 `../e2e-architecture-review/backend-media-event-loop-probe.py` 与 `.txt` 用真实 route + 注入 250ms 的同步 stub，10ms 定时器约 250.47ms 才执行，退出码 0。这个结果证明调用方式可阻塞事件循环；250ms 是注入值，不是生产 S3 性能、并发容量或用户故障测量。业务媒体链与 Matrix E2EE 附件边界应分别描述。

最小任务：先只改上述可达 signed-content 路径及同类已核实直接调用，不顺带迁移存储/改变鉴权。涉及 `services/business-api/app/api/media_platform.py`；若统一同步执行边界，连同 `app/api/profile.py` 与媒体 service/repository 的 session 生命周期做定向复核。优先让无 await 的同步 handler 交由框架受限线程池执行，或将完整同步工作单元明确放入受限执行器；不能把同一 SQLAlchemy Session 跨线程共享，也不能创建无界线程/任务。整对象内存、请求并发、S3 超时仍需有界；仅把 I/O 移出事件循环不代表已经消除所有内存/吞吐问题。

测试/验收：在隔离环境给真实 route 注入可控阻塞 storage，先得到 RED，再验证其未完成时独立轻量请求/事件循环哨兵已经完成；用同步屏障判断非阻塞，避免只凭一次睡眠时间作脆弱断言。覆盖超时、取消、拒绝/失效签名、跨用户、限长、session 清理与容量上限。复用 `tests/business_api/media_platform/test_media_gateway.py`、`test_media_authorization.py`、`tests/business_api/media_platform_readiness/test_concurrency_races.py`，再跑变更影响所需总门禁。隔离 S3 故障/并发测试记录 worker 数、池大小、对象分布、时延与峰值 RSS。保持状态码、签名 scope/过期规则和 E2EE/业务权威边界不变；没有真实 S3/并发证据前不宣称已达到生产 P95/P99。

回退：使用发布前已记录镜像/配置恢复业务 API，不改变 schema 或 S3 数据归属，不删除/迁回已落 S3 的对象。回退仍须保留当前鉴权协议及已部署兼容修复，不能用笼统旧镜像覆盖未经核验的其他发布差异。

### 2. Outbox：当前有效待处理为 0，历史 DEAD 需要独立治理

第一次聚合看到 PENDING 2；第二次依据已有 handover disposition、notice digest 与 SMTP receipt 验证，两条均已有效 supersede。当前未 supersede 的 PENDING/FAILED/PROCESSING 为 0；不能把历史两条视作本次积压。

最近 24 小时创建的 5222 条均为 PUBLISHED，最多尝试 1 次。发布记账时延 P50=0.4997745s、P95=0.9351461s、P99=0.94234269s、最大=1.102322s。这表示消费者完成/发布记录，不证明邮件到收件箱或推送到设备，也不代表峰值负载下的 SLO。

全历史 DEAD=103235（最晚创建 2026-09-30），其中有效 supersede 361、未 supersede 102874；允许的错误分类为 unregistered_topic 103230、other_redacted 5。最大 attempts=56947 是历史行，不可据此断言当前 worker 正在无限重试。历史异常和当前健康发布可以同时成立，不能因目前无待处理而抹除历史审计。

运行 worker AST 证实 `run_once:149` 先同步 maintenance（150），再 claim_batch（153）、串行 handler（161）、mark_succeeded（184）、heartbeat（185）。因此慢维护/慢 topic 可能阻塞其他工作，但现场没有证实这正在形成积压。实际 app import 根目录是 `/usr/local/lib/python3.12/site-packages/app`；worker 自身为 `/opt/business-worker/app/worker.py`。API 与 worker 镜像/部分文件字节 SHA 不同，不能只改一个错误 overlay 路径，也不能仅凭字节 SHA 差异推断语义漂移。

最小任务（P2，先观测再隔离）：在现有 Outbox 状态、receipt、重试与 supersession 语义之上增加按有限 topic 分类的有效 queue age、in-flight age、handler duration、dead 增量、claim/receipt 冲突指标。若隔离复现维护/handler 阻塞，再按 topic/维护职责隔离执行与预算，或补可证明正确的租约续期；不得直接并行共享 session、重放历史 DEAD 或从 Matrix/推送结果反向修改账本。

文件/测试：`services/business-worker/app/worker.py`、`main.py`、`services/business-api/app/core/outbox.py` 与既有 handover 接口；`tests/business_worker/test_worker.py`、`tests/business_api/test_outbox.py`、`test_outbox_handover.py`、`tests/business_api/audit/test_outbox_publication_receipts.py`。隔离 PostgreSQL 做慢 handler、进程崩溃、租约过期、重复投递、receipt 唯一、superseded 不再投递的 RED/GREEN。验收无丢失、既有幂等金融副作用不重复、短任务不被长 maintenance 无限阻塞；窗口、超时与恢复时间先明确后测量。历史 DEAD 单独出带审批/审计的处置方案，不作为性能优化顺手删除。回退仅 worker 调度实现/配置，保留兼容 schema、事件及 receipt。

### 3. 数据库：未观察到瞬时连接/锁压力，不足以决定索引或池调优

| 项目 | business PostgreSQL | Matrix PostgreSQL |
| --- | --- | --- |
| 版本 | 16.9 | 16.9 |
| 数据库字节 | 399880675 | 197980643 |
| max_connections | 100 | 250 |
| 采样连接（排除查询自身） | 22，均 idle/ClientRead | 35，均 idle/ClientRead |
| invalid/not_ready 索引 | 0/0 | 0/0 |
| 索引数 | 347 | 326 |
| 累计 deadlocks/conflicts | 0/0 | 0/0 |

业务 schema revision=`0095_wallet_source_alerts`。business 较大表为 audit_events 151609344 字节、outbox_events 108331008 字节、ledger_manual_reserve_evaluations 107601920 字节；outbox 有近期 autovacuum。以上是聚合元数据，未读事件或账本正文。索引 zero-scans、seq_scan、rollback 是累计计数，stats_reset 为空；不能据此删除索引、把回滚全部当异常或认定全表扫描就是慢查询。

最小任务：先复用现有监控采集正常与峰值窗口的连接/锁等待、事务时长、池等候和按脱敏指纹聚合的慢查询增量，再决定索引/池参数。当前 API 配置 2 workers；现场 DB_POOL_SIZE/MAX_OVERFLOW 未设置，任何池预算必须核对实际导入实现和所有客户端总额，不能简单增大池与 worker 数。数据库无现时 P0/P1 故障证据；当前不建议迁移、删索引或生产 EXPLAIN ANALYZE。

### 4. 健康与错误分类：正常 probe 拒绝不能当成刷新故障

服务器侧严格 TLS、禁 redirect、5s timeout 的实际健康 GET：`/api/v1/health/live` 200、ok=true、40.93ms；`/api/v1/health/ready` 200、ok=true、database=ready、41.06ms。`/api/v1/health` 不是代码注册路径，404 不说明健康故障。上述检查只证明这一时点/这一入口的轻量活性及 DB 就绪，不覆盖媒体、SMTP、推送或恢复材料端到端。

API 第二次 tail 50000 实际覆盖 UTC 2026-10-10 15:33:33 至 10-11 02:03:51，达到行上限：已知固定 `starchat_probe=1` 的 refresh 为 401 共 611；其他 refresh 为 200 共 128。`scripts/refresh_watchdog.py:112-121` 的协议探针故意使用无效测试 token 并期待 401/REFRESH_TOKEN_INVALID；本次没有再执行该 POST。固定 query 标志是分类标签，不是独立证明请求来源的身份认证。标准 refresh reason marker 与客户端 refresh stage 分类在这段样本未出现，不能从缺失推断没有故障。

第一次 API 文本关键字 timeout 命中 271 是关键词行数，可能包含正常 timeout 字段，不能称 271 次超时；worker ERROR 关键字命中 1 而结构化异常分类没有匹配，也不能据此宣称一次已确认业务事故。只保留解析器范围内的计数及缺口。最小观测改进是继续区分已知 probe 与实际业务请求、只输出有限 reason code 和时延桶，不增加 token、请求正文或用户高基数标签。

### 5. Pusher 注册聚合补充

只查已知 app_id 类别与 APS sound 是否固定 default：Android Getui 23，aps.sound 缺失；iOS APNs 10，均为 default。这是注册行计数，不是唯一用户、可达设备或推送成功率；Android 不使用 APS sound，缺失不是故障。不得据此推断用户真实静音偏好或系统弹横幅状态。设备投递/渠道问题由 push 评审另行闭环。

### 6. 恢复鉴权端口问题的独立质量/安全复核

主审 `root-recovery-authority.jsonl` / `root-recovery-metadata.jsonl`：运行 RecoveryVaultModule enabled=true；实际模块 `/usr/local/lib/python3.12/site-packages/chatflow_recovery_vault.py`，SHA `6ebcc5bdf0be699660eed77137ae33132a39e8e6c280b10cf3517d42bad599ab`；AUTHORITY 固定 business-api:8000/既有 matrix-recovery-authorize 路径；从 Synapse 容器 TCP 8000 拒绝、8082 连通。没有发送恢复鉴权请求或读取密钥。本地 handler 在分支前 verify（`third_party/synapse/chatflow_recovery_vault.py:328`），其连接异常映射 503（259-260），故端口不匹配足以使通过 native 鉴权并到达上游的调用失败。历史 503 与其相容，不能逐条归因，不能概括全部历史 iOS 登录原因。8082 TCP 连通仍不证明鉴权端点契约已通过。

P1 最小修复建议可接受：内部固定目标修正为既有 8082，补 topology/port 契约 RED 和真实隔离同拓扑 GET status；保留双凭据、撤权复查、失败关闭、固定 host/path 与超时，不加失败放行或任意 URL。`status` 在 verify 后仍加载 keyring（331），因此隔离测试必须使用测试身份和测试 keyring，不能读取生产恢复材料。复用 `tests/infra/test_synapse_recovery_vault.py:85,161` 的撤权/过期/锁定/不泄露用例，补端口契约，不声称仅改端口就完成 E2EE 或恢复能力验收。不改变 E2EE/托管策略或金融权威；按受保护域要求做领域及质量/安全审查。部署与生产状态/恢复验证须受后续明确授权范围约束。

## 下一步与不足

1. 主审整合端口 P1 与媒体 P1，建立独立实施任务、测试身份和回退清单；本记录仅方案与现场证据，未实施。
2. 运行文件与源码身份在发布前再次核验；尤其 worker 的实际 import 目录，避免文件覆盖到未执行路径。按既有发布工作流及安全门禁交付，不扩大为整体旧镜像替换。
3. 当前没有真实生产 S3 慢调用、峰值混合负载、长时队列压力、锁等待时间序列或新灾备恢复数据。单点健康、24 小时新增 Outbox 成功、截尾日志与本地合成证明各自有限，不能互相替代。

文档完成时间：2026-10-11；代码/配置/服务器均未由本子任务更改。
