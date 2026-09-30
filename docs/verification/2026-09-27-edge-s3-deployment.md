# 边缘/TURN 与 S3 部署验证

更新：2026-09-27 21:35+08。本批分阶段部署及有限存量验收完成；香港仍为业务权威和主区。

当前：SG边缘/TURN及HK五条TURN候选已上线；业务API1aa6/worker0e011于20:14 S3主写上线，切写后三类fresh扫描COMPLETE，108对象远端校验、本地保留。Synapse996两进程19:44同步S3写上线，43批有限回填21:21:30完成；21:22权威快照2923有效媒体全部匹配S3路径/大小，缺失及大小不符0。五分钟存储timer enabled/active、service Exec0、最终OK/alerts0。实际四服务及SG两容器healthy/0restart、API契约与路由拒绝保持。整体健康仍ATTENTION：21:31快照有431个兼容后新创建的DEAD，全部为已有主题未注册消费者，媒体cleanup和真实已注册handler失败0；这是持续契约缺口，不是纯历史记录。不重放事件/修改金融状态。后文16:34及候选章节均为阶段历史，最后更新给出实际完成证据和限制。

## 16:34阶段历史：已部署和现场证明

- SG Docker25.0.16与固定镜像已安装；根盘仍40GiB，原completed快照保留。
- `starchat-sg-edge-nginx-20260927` 正常运行，固定nginx digest与只读配置SHA b8457b68。
  香港经公网定向SG443、保留SNI/证书验证：API JSON200且ok/database ready、register403、admin404、
  未知SNI拒绝。主域名仍香港，未导流正常用户API；真实客户端IP可信链尚未启用。
- 一个SG桶 `starchat-media-218022113852-sg` 已创建：四项BPA、默认AES256、TLS-only、无lifecycle、
  版本化未启用。没有创建HK桶、迁移生产对象或删除本地媒体。
- 实例角色真实AWS HTTPS证明：两前缀CRUD/SHA256/SSE/MaxKeys1分页/严格404；冻结Synapse类实际
  写读、兼容回退、远端删除重试、永久fence拒绝迟到写。9个synthetic对象已精确清理并确认404/前缀空。
  这不替代香港身份与完整Synapse/PG/多worker生命周期测试。

## 源码与验证

独立worktree为 `C:/Users/Administrator/.codex/worktrees/sg-edge-s3/StarChat`；禁止将整个脏树部署。

- TDD红/绿：边缘、TURN追加渲染、Synapse渲染/provider/删除、业务字节/双读/迁移及旧头像清理。
  根infra相关110项通过；业务原45及208项回归通过；7项新头像提交失败/退役病例通过，应用后86、最终219项受影响测试通过。
- 业务与Synapse先规格/领域后独立质量安全审查；候选通过。旧头像Outbox不泄漏进幂等响应；
  worker先于API发布；远端故障时旧签名URL也不能读退役头像。
- 真实固定Synapse1.132镜像164052da构建/pip check/实际Twisted与FileResponder冒烟通过。
  本地真实HTTP S3 fixture11项通过、无持久卷；真实AWS字节proof见上。
- 完整 `scripts/verify.ps1` 已运行：仓库/部署/模板/render、infra227、桥28、bot9通过；
  Business2955通过/89有条件跳过/1失败，失败是worker旧SimpleNamespace fixture缺新local配置。
  该失败原日志保留；test-only修正已复测闭环，未对生产配置静默fallback。
- 按未变输入复用规则继续运行余下门禁：mobile108通过/1条件跳过、UI32components/403screens、
  导入、AST274、唯一0090/offline迁移、OpenAPI、Compose全部通过。没有把原full gate退出1改称退出0。
  已知Starlette/httpx和Pydantic弃用警告保留，非本批引入；pip root warning对应候选容器构建。
- 16份公开infra文件SHA保护回填main；业务main回填发现并保留另任务最新启动诊断receiver，
  只重放S3接线；业务21份文件SHA保护回填，当前main.py SHA363e313a。最新启动tracing隐私补丁作为
  只读基线保留，最终精确OpenAPI与136张ORM定义对照一致、219测试通过。默认local，无公开API/schema破坏性变化。

## 历史用户输入与生产门禁（18:58更新见下）

1. EIP查询为空：13.229.60.153为自动公网IP。用户关联固定EIP，变更IP时同步DNS并告知。
2. Secrets Manager读成功、字段完整，但HK程序身份STS返回InvalidClientTokenId；需修正同一已启用
   身份的两个访问密钥并绑定限定hk-media-identity-policy，不能发送值到聊天。
3. 同步修订的maintenance-policy，仅为指定秘密增加PutSecretValue，方便把既有TURN密钥安全纳入
   Secret Manager；这是infra/AGENTS生产秘密源要求。传输脚本只是暂存候选，未执行，真实密钥未读出。

输入到位后必须先复核公网IP/DNS、身份/限定权限，安全保存凭据到服务器0600 SDK文件；禁止Docker
secret env/argv与本机密钥文件。再完成TURN认证、公网UDP/TCP双向relay、私网拒绝与配额；最后经模板
追加HK候选，保留HK。当前仅nginx运行，未配置/公布SG TURN。

业务须所有writers/worker/GC先兼容local_s3_read，再元数据守卫dry-run/分页拷贝/逐对象校验/单写S3，
不删除本地。Synapse须完整PG多worker、pending/retiring/quarantine、故障恢复/孤对象扫描、DB守卫迁移、
回退证明；fence须永久保留。进程可在迟到PUT后崩溃留下不可读密文孤对象，不能承诺零孤对象。
香港实际serving路径p95/失败率与成本仍需量化，不能把SG角色CRUD延迟当用户媒体体验。
ADR要求的backend错误/延迟、桶增长与GC回收观测告警仍是启用门禁，候选通过不等于观测完整。

## 证据入口

- [部署](artifacts/2026-09-27/edge-s3-deployment/nginx-deployed.json)、[公网定向验收](artifacts/2026-09-27/edge-s3-deployment/edge-public-proof-fixed.json)
- [权限与秘密状态](artifacts/2026-09-27/edge-s3-deployment/aws-scoped-ready-code.json)、[EIP/安全组](artifacts/2026-09-27/edge-s3-deployment/aws-preflight-ready.json)
- [桶配置](artifacts/2026-09-27/edge-s3-deployment/sg-s3-provisioned.json)、[真实AWS存储](artifacts/2026-09-27/edge-s3-deployment/sg-s3-real-http.json)
- [Synapse独立评审](artifacts/2026-09-27/edge-s3-deployment/synapse-independent-review.json)、[实际镜像冒烟](artifacts/2026-09-27/edge-s3-deployment/synapse-image-smoke-fixed.log)
- [完整门禁原日志](artifacts/2026-09-27/edge-s3-deployment/full-verify.log)、[余下门禁](artifacts/2026-09-27/edge-s3-deployment/verify-remaining.log)
- [infra输入回填](artifacts/2026-09-27/edge-s3-deployment/infra-main-integration.json)、[受影响infra](artifacts/2026-09-27/edge-s3-deployment/infra-focused-final.log)
- [资源/价格结论](2026-09-27-storage-database-cost.md)、[AWS所需动作](2026-09-27-edge-s3-aws-access.md)

当前不用追加磁盘或购买RDS：香港根盘33%/140G可用，新加坡40GiB满足无状态边缘准备。若仅容量，
新加坡gp3新增100GB约$9.60/月，明显低于示例RDS t4g.medium+100GB单AZ$88.26/月；S3/数据库解决
不同问题，出网费需单独计。主区选择仍等真实用户更新后7–14天观测，不在本批切换。

实际PostgreSQL16.9两种迁移/GC锁序证明通过；原fixture排序无关金融表触发的SAWarning保留，
后续收窄为明确User/media表集再次验证，不改金融schema。完整PG/Synapse集成仍不由此替代。
`docker-compose.yml`/`.env.example`新增公开可选配置已独立先规格后安全审查通过；API与worker映射一致，默认local/SG URI空，无AWS凭据值。实际Compose默认与兼容模式传播检查通过，见[配置评审](artifacts/2026-09-27/edge-s3-deployment/optional-configuration-review.json)及[传播验收](artifacts/2026-09-27/edge-s3-deployment/compose-storage-wiring.json)。

最终业务公开证据已回填：
[219项受影响测试](artifacts/2026-09-27/edge-s3-deployment/business-final-focused.log)、
[真实PG两种并发顺序](artifacts/2026-09-27/edge-s3-deployment/business-postgres-concurrency.log)、
[先规格后安全评审](artifacts/2026-09-27/edge-s3-deployment/business-review.json)、
[精确契约和表定义](artifacts/2026-09-27/edge-s3-deployment/business-contract-comparison.json)、
[候选SHA](artifacts/2026-09-27/edge-s3-deployment/business-candidate-manifest.json)、
[21文件主目录保护整合](artifacts/2026-09-27/edge-s3-deployment/business-main-integration.json)。
PG收窄表集复跑没有fixture警告；startup受影响133项通过；最终独立规格、安全均通过，
activation_ready=false，保留监控/生产生命周期门禁。业务candidate SHA ee591df073d38498d6407a745a6d4bdca6c5c2ce2418b37573a661c43f541a08。

## 2026-09-27 18:58实际执行更新

用户输入均已闭环，不再缺EIP、DNS、IAM或Secrets Manager字段。固定TURN4.13.1已通过实际公网UDP/TCP双向ChannelData、私网与过期鉴权拒绝、配额；香港18:43追加两条SG URI，保留旧HK三条，仅原镜像Synapse重启、24其他Compose容器不变。新EIP定向严格TLS复核ready200/register403/admin404/未知SNI拒绝。

- [TURN公网](artifacts/2026-09-27/edge-s3-deployment/turn-v2-public-live.json)、[配额](artifacts/2026-09-27/edge-s3-deployment/turn-v2-user-quota-live.json)、[发布](artifacts/2026-09-27/edge-s3-deployment/turn-advertisement-published.json)、[发布后TLS](artifacts/2026-09-27/edge-s3-deployment/post-turn-edge-probe.json)。没有认证生产账户或真机证据。
- [生产数据库隔离恢复](artifacts/2026-09-27/edge-s3-deployment/production-database-restore.json)：业务138表/0090_friend_discovery_index、Synapse168表一致；私有dump和恢复数据不导出，生产无SQL写入。
- [HK真实S3延迟和只读清单](artifacts/2026-09-27/hk-s3-latency-inventory/hk-s3-readonly-report.json)：20次64KiB PUT p95约139.55ms、GET含正文p95约78.25ms；不代表大文件/并发/真实用户端性能。
- [实际Linux候选审查](artifacts/2026-09-27/edge-s3-deployment/independent-linux-runtime-review-final.json)：API55ac/worker0e011实际55/52测试通过、14/15来源哈希及固定SDK通过，OpenAPI与live324路径完全一致；兼容compose已冻结但尚未执行发布。
- [Synapse runner候选](artifacts/2026-09-27/edge-s3-deployment/synapse-backfill-candidate-summary.json)、[独立规格/安全95测试](artifacts/2026-09-27/synapse-backfill-independent/review.json)、[实际公共接口及竞态证明](artifacts/2026-09-27/edge-s3-deployment/sg-synapse-backfill-public.json)。作者100测试多含dedup门禁，范围不与独立95混合；生产真实Redis、writer配置和有界迁移仍待执行。

生产S3媒体未迁移、源文件未删除。旧章节的InvalidClientTokenId/无EIP/TURN未公布已被本更新取代；不能将候选或隔离恢复称作生产S3已启用。

## 2026-09-27 20:19+08 实际S3主写上线

PHONE-only独立发布基线1aa6与原S3覆盖14/14源文件完全一致，worker0e011原15/15一致；实际324路径OpenAPI SHA a689…不变且startup route absent。新的兼容v3配置仅API image变化，精确输入路径/SHA门禁；新driver7f65、publisherafdf、wrapper67df经3 RED→23 GREEN与独立规格→质量/安全审查通过。全源/SDK不需重跑未受影响的核心PG/E2EE门禁。

重新开始的三类dry与baseline enforce均COMPLETE：platform0，头像58扫描/35跳过/23远端已存在，朋友圈108扫描/23跳过/85远端已存在，33,696,190字节再校验。20:14:10 worker先切、20:14:25 API切新S3模式，均healthy/0restart，固定1aa6/0e011镜像；23其他Compose容器保持。S3为主写/主读，本地明确miss回落；回退保持同镜像local_s3_read，不丢新S3-only文件。旧失败发布/回退与并行漂移拒绝证据继续保留。

Synapse真实19:43:14→19:44:10三阶段、每阶段先sync后main，996固定镜像，27其他容器不变。最初namespace守护误包含PG cp_max，实际只读确认仅池容量不同；仅去cp_min/cp_max的新a23守护保留DBendpoint/auth/adapter/options、完整Redis与server_name，6测试/16额外断言/独立复审通过，真实两live+maintenance身份一致。首两批77复制+1校验、64复制，共43,377,726字节；循环有界迁移进行中，未完成不能宣称全量。

20:17存储timer恢复enabled/active、service Exec0；新配对样本OK/alerts0，业务108对象33,696,190字节、Synapse225对象63,991,112字节（非原子快照，回填仍继续）；平台GC错误和业务SDK日志错误0，实际LIST probe521ms。这不是用户请求延迟。探测容器继续使用固定55ac只读源码访问相同DB/LIST，实际API已为1aa6，不借fresh-exec读取冒充线上进程metrics。发布间暂停监控已结束。

20:19实际健康复核：API/worker/Synapse/sync均healthy/0restart、来源哈希及实际s3模式通过；严格TLS ready/Matrix JSON200、register403/admin404/未认证诊断及搜索401通过。整体ATTENTION如实保留：worker9条原有未注册consumer汇总；API及两个Synapse当前窗所有错误类0、存储和数据库错误0。此前phone发布后的唯一API traceback来自diagnostics读请求体中断（class由已核验raising源码推断ClientDisconnect），与S3/phone实现无关；不删除历史告警、不擅自重放Outbox。

证据：[业务S3发布](artifacts/2026-09-27/edge-s3-deployment/business-s3-write-published-v3.json)、[新基线审查](artifacts/2026-09-27/edge-s3-deployment/business-phone-baseline-review.json)、[Synapse三阶段](artifacts/2026-09-27/edge-s3-deployment/synapse-s3-published.jsonl)、[实际回填门禁](artifacts/2026-09-27/edge-s3-deployment/synapse-backfill-assessment-v2.json)、[监控恢复](artifacts/2026-09-27/edge-s3-deployment/media-storage-monitor-resumed.json)、[实际健康ATTENTION](artifacts/2026-09-27/edge-s3-deployment/post-business-s3-health.json)、[诊断中断分类](artifacts/2026-09-27/edge-s3-deployment/post-phone-log-attention-classification.json)。

当前剩余部署动作：新fresh workspace业务补扫完成记录、Synapse全部bounded inventory扫描及最终只读覆盖审计、最终监控/健康。真实用户附件/通话、Native IPv6 relay及7–14天主区选址观测保留为外部验收缺口；没有缺AWS权限或设备输入。全renderer仍有原有modules/nginx实质漂移，禁止本批覆盖网关规则；不称完整verify或全renderer已绿。

## 2026-09-27 20:46+08 切写后扫描与真实进程指标

业务切写后的新鲜三类dry/enforce已完成，旧游标保留而新轮次不复用已结束游标。实际扫描166行、58跳过，23头像及85朋友圈共108对象/33,696,190字节远端再校验，本地字节和数据库元数据保留；platform当前0对象。私有cursor、PENDING和audit只留服务器。[实际完成记录](artifacts/2026-09-27/edge-s3-deployment/business-postflip-completed.json)及[独立9测试与规格/安全审查](artifacts/2026-09-27/edge-s3-deployment/root-business-postflip-review.json)支持本次有限存量扫描，不能当作未来上传、GC或真实用户端到端证明。

利用容器中已有维护令牌，仅内存构造固定loopback的两个只读GET；不创建凭据或会话，不导出完整响应、路由、operation ID、用户标识或消息。真实当前1aa6 API HTTP快照包含30匿名请求序列、2497窗口样本，S3 GET累计690次且全部success；最近256次SDK GET p50 74.366ms、p95 757.686ms、p99 3215.627ms、max4260.963ms。该进程PUT/exists/delete/list计数为0。probe 5测试及根独立复测通过，规格→质量/安全通过。

[真实进程指标](artifacts/2026-09-27/edge-s3-deployment/media-process-live-metrics.json)和[根独立审查](artifacts/2026-09-27/edge-s3-deployment/root-live-media-metrics-review.json)区别于fresh-exec空collector或仅检查wiring。计数为进程生命周期、耗时为有限滚动窗口，未提供文件大小/用户地区/运营商/同条件香港旧后端对照；不能归因长尾，不能声称体验改善或据此迁主区。Synapse历史回填仍继续，各批保留源/provider/Redis守护、远端摘要校验与有界准入；当前尚不宣称完成。

[独立性能口径审查](artifacts/2026-09-27/edge-s3-deployment/independent-s3-performance-interpretation.json)确认GET计时包含全部正文读取、SHA256计算、可用FULL_OBJECT校验、buffer及close，并非纯RTT/首字节或客户端交付；Dual与S3的p95/p99近似且fallback0。SDK显式connect3秒/read15秒/standard总3尝试/单client连接池20，但没有整段操作硬deadline、实际重试/连接复用/对象大小统计；终态成功不排除已恢复重试。先前20×64KiB顺序probe与当前未知大小/并发、不同重试控制和时段不等价。网络、文件大小、回填资源竞争与CPU原因均未证实，本批不以猜测加入缓存或改变授权。

## 2026-09-27 21:31+08 有限回填和最终覆盖完成

Synapse历史回填43批全部PASS，最后一批21:20:38→21:21:30、exit0、scan_completed=true。累计2800复制、96远端再校验、881,098,438字节；分媒体中断后重入会重复校验原始对象，累加值不等于唯一对象清单或唯一字节。所有批均保留本地数据、不取消SDK尾部、执行前后验证live source/provider/Redis。核心migration_coverage_complete字段仍false，不能将它篡改为所有未来用户媒体或完整生命周期完成。[批次摘要与43份SHA](artifacts/2026-09-27/edge-s3-deployment/synapse-backfill-completed.json)。

随后独立只读覆盖审计PASS：REPEATABLE READ、READ ONLY及新事务稳定性断言，按DB生命周期/授权/摘要条件得到2692有效原始、231有效缩略图，合计2923对象/897,545,799字节；全prefix有界LIST三页2924对象，另一个为永久fence，有效媒体被fence0。2923对象路径和长度全部匹配，missing0、length mismatch0；无PUT/DELETE/读取媒体正文、无ID/digest输出。它是当次稳定元数据快照，不是原子S3快照或新的逐对象GET摘要校验；历史字节验证证据来自有界回填。审计观察期间前后配置/source/SDK身份保持。[实际覆盖](artifacts/2026-09-27/edge-s3-deployment/synapse-snapshot-coverage.json)及[独立17测试审查](artifacts/2026-09-27/edge-s3-deployment/independent-synapse-coverage-review.json)。

最终五分钟timer enabled/active，手动触发当前只读service Exec0、OK/alerts0；有界LIST probe1127ms、平台GC与SDK错误0。此后一时刻3034桶对象/931,295,145字节与覆盖审计2924不同，是持续新写入下非原子不同快照；不按两个总数直接推断泄漏。platform GC配对仍仅business/media/且当前0，未执行真实生产GC或清理本地。原检查点、审计、备份和恢复配置继续私有保留。[最终监控](artifacts/2026-09-27/edge-s3-deployment/media-storage-monitor-final.json)。

21:22真实API已有维护token HTTP快照：S3 GET1880/1880 success，fallback及其余终态分类0；最近256次p50 71.599ms、p95 1164.129ms、p99 1782.615ms、max3175.868ms。沿用独立5测试通过的aaf902 probe，不创建凭据/会话，不读取fresh collector；仍不推断用户p95或改善/退化。[最终指标](artifacts/2026-09-27/edge-s3-deployment/media-process-final-live-metrics.json)。

最终四香港服务healthy/0restart、S3设置及14/15 source SHA、OpenAPI324/a689合同、严格TLS ready/Matrix200与403/404/401拒绝保持。整体ATTENTION/exit1如实保留：worker134未注册consumer/错误汇总，API及两个Synapse所有错误分类0，四服务storage/database/disk错误0。最终只读Outbox聚合102121个DEAD创建于兼容切换前，399个创建于切换后；cleanup incomplete/failed/dead均0。新的399仍需要单独分类，不用早前new0结论覆盖它，也不重放任何事件。[健康ATTENTION](artifacts/2026-09-27/edge-s3-deployment/final-media-production-health.json)、[最终Outbox聚合](artifacts/2026-09-27/edge-s3-deployment/business-outbox-final-aggregate.json)。

21:26新EIP定向严格TLS ready JSON200/register403/admin404/未知SNI拒绝再次通过；21:30 SG nginx/coturn均healthy/0restart、显式digest、host network、只读根FS、Docker持久volume0、日志10m×3；根FS39.93GiB、可用约36.57GiB。原公网TURN UDP/TCP双向和配额验证在源/配置未变条件下复用。[最新EIP检查](artifacts/2026-09-27/edge-s3-deployment/final-edge-eip-public.json)、[SG运行检查](artifacts/2026-09-27/edge-s3-deployment/final-sg-edge-runtime.json)。

AWS输入无缺项；本批不加盘/购RDS、迁主区、全模板覆盖网关、删除本地数据或发布未批准startup API。真实认证用户附件/通话、Native IPv6与7–14天真实用户区域对照仍待客户端使用日志；本轮有限扫描/快照通过不能替代这些外部体验验收。全verify原失败及全renderer既有漂移保留，不声称全绿。

## 2026-09-27 21:35+08 Outbox持续缺口的最终分类

首次只读classifier在SQL保留字WINDOW别名关闭失败，无生产写；最小event_window修正新增1 RED→7 GREEN、Ruff/生成Python编译及根独立7测试通过，规格→质量安全复审通过。实际1aa6/0e011及manifest全部source SHA、运行日志的9个registered topics与冻结源码分支union守护；不构造financial worker或重放事件。DB明确REPEATABLE READ/READ ONLY并SHOW验证，connect5秒/statement10秒/lock2秒，只有固定分类计数输出，无topic/error/ID/payload原文。

13:31:40UTC（21:31:40+08）的当次快照：兼容前创建的当前DEAD102121（其中361个topic现在已有consumer，但旧无消费者标记仍保留，未证明投递结果）；兼容后新创建DEAD431，按created_at分为兼容195、S3写236。431全部属于历史旧DEAD已有且当前仍未注册的topic，last_error精确“无consumer”类别；unknown/registered新DEAD0。媒体cleanup incomplete/failed/dead均0，当前有界worker日志149无消费者汇总、已注册handler deadletter/retry、媒体失败、maintenance/storage模式均0。没有死亡时间字段，created_at分窗不证明死亡发生时间、因果或用户端结果；日志与DB不是原子快照，当前容器重建后不含兼容前日志。

结论：未发现本批S3新增处理器回归，媒体部署/当次有限扫描可结束；已有消费者契约缺口持续产生新死信，整体ATTENTION保留，需独立修复。不能用较早new0或把431说成仅旧历史数据；不自动补写资金状态/重放未知事件。[实际只读分类](artifacts/2026-09-27/edge-s3-deployment/final-outbox-provenance-readonly.json)、[根最终审查](artifacts/2026-09-27/edge-s3-deployment/root-final-outbox-review.json)。

最终独立规格→质量/安全证据审查为REVIEWED_WITH_OPEN_ATTENTION：43份批次SHA/守护与重算值、业务postflip、Synapse快照、最新EIP/SG运行、监控和实际HTTP指标一致，允许结束本批部署及当次有限扫描；持续Outbox、全renderer漂移、真实附件/ICE/Native IPv6、7–14天选址及跨进程持久指标/外部告警不能称已完成。旧44输入/022批运营审查只是当时历史快照，最新收据与全43批以本最终审查为准。[最终独立审查](artifacts/2026-09-27/edge-s3-deployment/independent-final-deployment-evidence-review.json)。
