# ADR-0086：媒体字节存储对象化（S3 后端，边缘/多节点共用）

日期：2026-09-26。状态：**用户已授权，分批上线及当次有限存量扫描/快照覆盖通过（2026-09-27 21:26+08）**。
2026-09-27用户明确要求部署边缘/TURN与S3媒体存储；继承原方案的单区权威、隔离域、授权和回退边界。
按[部署计划](../superpowers/plans/2026-09-27-edge-s3-deployment.md)执行，不重复要求批准相同部署。
AWS权限/服务身份和真实provider生命周期门禁已通过；实际发布与持续覆盖状态见[部署记录](../workflow/tasks/2026-09-27-edge-s3-deployment.md)。

2026-09-27实际状态：业务API/worker于20:14切为S3主写并保留本地回读，保留另一获批PHONE-only修复；Synapse main/sync于19:44完成三个兼容阶段后启用同步S3写，原TURN五条与鉴权模块保持。旧头像/朋友圈108对象已校验复制，业务切写后新鲜补扫已完成；Synapse 43批有限扫描21:21完成，随后权威只读快照的2923有效对象全部匹配S3路径/大小。全部本地字节保留，不以累加批次校验字节作为唯一容量或承诺未来媒体覆盖。五分钟只读容量/平台GC聚合与本地告警enabled/active、最终OK；真实API的1880次S3 GET均成功，最近256次SDK耗时p95约1.164s/p99约1.783s，只是单进程滚动窗口。Outbox最终仍ATTENTION、原有全renderer漂移保留；完整生命周期/用户体验及7–14天选址窗口未证明。业务数据库和API权威仍在香港，未迁主区。

2026-09-26 用户批准的是[选址观测增量](../superpowers/specs/2026-09-26-regional-measurement-design.md)
及文档纠错，当时不含本S3提案；这一段是历史授权记录，已由上述9月27日明确部署要求扩展。
该增量的网络摘要与安全收集边界见[观测手册](../runbooks/network-probes.md)：它只提供现有
primary_api的有限覆盖元数据，不测S3读写、媒体完整链路或候选区域，不能据此完成本提案选型。

## 背景与替代关系

实施前的2026-09-26设计基线为媒体字节落在香港单机本地卷：Synapse 媒体库（`./data/synapse`，含 ADR-0060
`chatflow_media_dedup` 的密文 blob 内容寻址索引）与业务媒体平台（`./data/business-media`，
`LocalBlobBackend`，schema 0069 七表，隔离域/摘要种类/签名 URL/GC 边界由
[Phase 3.1 架构冻结](../architecture/media-engine-phase3-freeze.md) ADR-001…006 锁定）。单机磁盘
容量、备份与容灾仍需按实际运行态核验；规划中的[新加坡边缘节点](../runbooks/singapore-edge-node.md)
（原8GB规划已于9月27日在线扩为40GiB）按本草案角色不承载业务数据。对象存储是解除本地字节依赖的一种
候选，不是新增边缘节点的前置条件，也不代表可以立即迁移主站。

本 ADR **不替代、不修订**上述冻结结论：隔离域 key 布局、三种 `digest_kind`、确定性信封密文去重、
签名 URL 授权、GC 生命周期、"Matrix 字节不迁入业务平台/平台不重加密/CDN 不参与授权"原样生效。
本提案的 Synapse 存储后端变化仍在其自身媒体命名空间内，不改变字节归属或加密边界。
替代方案：① 维持本地卷并扩容（不解决单机故障域与跨节点共用）；② 仅 Synapse 侧上 S3（业务平台
仍是本地卷，问题只解决一半）；③ 自建分布式存储（运维成本与规模不匹配）。本 ADR 取
"平台侧 `BlobBackend` 抽象新增 S3 实现 + Synapse 媒体库生命周期感知的S3 provider"的组合。

**2026-09-27实施修正**：固定Synapse1.132.0和官方S3 provider均无删除接口，标准插件不能满足
本项目GC/发布失败补偿，因此不直接启用。候选在原共享引用/隔离/退役锁下先删除远端再清理本地/DB；
永久拒绝标记仅阻止已退役media_id的迟到缩略图写入/回读，不代替数据库授权与引用事实。新内容重传
使用新media_id。S3失败必须保留pending/retiring以恢复；标记不能由lifecycle删或回退撤掉。配置默认
关闭、同步存本域、不存remote cache、保持本地缓存。真实Synapse/PG/provider测试和独立领域/安全
审查通过后才启用；相关原“官方插件已覆盖保留/删除”假设均以此修正为准。

## 决策

1. **抽象不动协议**：业务平台沿用既有 `BlobBackend` Protocol（put/get/exists/delete 四操作，
   写必须原子），新增 `S3BlobBackend` 实现。只有确定的对象不存在才映射既有 `MEDIA_BLOB_MISSING`；
   权限拒绝、超时、限流/5xx 不得伪装成不存在，也不得据此 invalidate 元数据。key
   即对象 key，`media/{user|e2ee|public}/<scope_hash>/…` 布局与域守卫（`key_belongs_to_domain`）
   逐字节不变。后端选择经 `BUSINESS_MEDIA_BLOB_BACKEND=local|s3|local_s3_read` 配置，默认 `local`。
   四操作不覆盖孤对象发现：现 `MediaReconciler` 解析本地 root 并 `rglob`，须增加独立的内部
   对象枚举能力（限定平台 prefix、有界页大小、可续跑游标），用于 S3 孤对象重建；不能只换四操作
   实现便声称 reconcile 无回归。该内部能力不改变客户端/OpenAPI 契约。
2. **选型与凭据**：候选为 AWS S3，区域待实测和提案批准后确定，不锁定 `ap-southeast-1`。
   endpoint/region/bucket/prefix 经受保护的生产发布配置；凭据源为 Secrets Manager，
   SDK 默认凭据链读取服务器受保护的共享凭据文件，不入仓库、argv、日志或Docker环境。IAM 最小权限：
   仅限本桶本 prefix 的 GetObject/PutObject/DeleteObject/ListBucket；仅允许 TLS。测试用固定版本
   的本地 S3 兼容服务（如 MinIO 固定 digest），生产禁止自建 S3 兼容存储。
3. **E2EE 与静态加密**：SSE-S3 启用。`e2ee` 域字节本就是客户端密文，`user/public` 域获得静态
   保护——服务端静态加密不触碰 E2EE 边界，也不引入任何服务端明文化处理（解密/转码/全球明文
   去重均被冻结结论禁止，本 ADR 不新增）。禁止下发任何 S3 直链；客户端读取仍只能经业务签名
   URL 与 Synapse 鉴权端点。
4. **桶策略**：Block Public Access 全开；禁用 lifecycle 自动删除——删除只能经平台 GC 与 Synapse
   既有保留策略（`CHATFLOW_MEDIA_RETENTION_MS`）执行，防止 lifecycle 与 GC 竞态删除仍被引用
   的对象。版本化默认**关闭**（双后端共存不等于新对象已有本地副本，回退须满足第5项；如需开启须修订本
   ADR 并评估双倍成本）。
5. **迁移为 expand-only 双读、单一权威写后端**：①先在全部API/worker/GC发布兼容读取模式 `local_s3_read`，仅本地新写且可读S3历史对象；
   元数据守卫的dry-run/有界拷贝验证后，再写灰度——新写对象进 S3，读路径仅在明确
   S3 对象不存在时回落本地；②存量
   拷贝——有界、可续跑、幂等的作业（dry-run 先行，逐对象与库内 digest/长度校验后写入，缺
   digest 的旧对象边拷边记），审计落 `media_gc_runs` 同级台账；③一致性核验通过后读主切 S3；
   ④本地字节在观察期和回退门禁均满足后按 GC 正常回收。切 S3 后新增对象只在 S3，保留旧本地卷
   不能保证直接切回 local 后可读。回退必须采用经验证的兼容读取方案：停止新的 S3 写入、恢复
   local 单写但继续可读 S3 中的历史新对象；若要完全撤除 S3 依赖，先按权威元数据反向同步所有
   仍有效对象，逐对象核验 key/digest/长度并证明全量覆盖，再切纯 local 读取。回退流程须处理
   在途上传与 GC 并发、重试/续跑和隔离墓碑；不允许复制已删除/隔离对象使其恢复可见。
   S3 不可达时，兼容读取也不能保证 S3 独有对象可用，必须明确这一故障限制，不能承诺无损切换。
   业务平台与 Synapse 各自列独立迁移清单；**绝不重加密、绝不改 key、绝不跨越其字节归属命名空间**。
6. **Synapse 侧单独一步**：固定Synapse1.132.0派生镜像中的生命周期感知S3 provider作为后端，
   不直接启用没有删除接口的官方插件。同步存本域、保留本地缓存、删除前持久拒绝标记及失败重试
   以本页9月27日修正为准；兼容回退只停远端新写，历史S3读取/拒绝标记/远端GC保持启用。
   启用前必须先在隔离环境跑通 `chatflow_media_dedup` 集成套件——该模块直接操作媒体仓库生命
   周期（发布/retire/隔离墓碑/崩溃恢复），与外部存储层的兼容性是硬门禁，不得凭 provider 官方
   声明跳过。`CHATFLOW_MEDIA_DEDUP`/`CHATFLOW_MEDIA_RETENTION_MS` 行为不变；homeserver.yaml
   变更经 `render_config` 模板渲染并 `--check` 无漂移。
7. **生命周期与审计**：引用计数、GC 状态机、reconcile、隔离（quarantine）全部基于数据库权威
   状态不变；S3 后端删除即 deleteObject，审计行保留。共存窗口需明确两端清理与墓碑规则，
   防止旧副本回读或 reconcile 复活。`reconcile` 的孤对象重建按 key 的隔离段判定摘要种类，
   该规则不变，扫描实现必须使用第1项的枚举/游标能力。
8. **区域与读延迟**：单桶起步，区域待确定；不能用未测量的固定跨区域 RTT 作为验收事实。
   对候选区域分别测量香港 serving 路径的 p95、失败率、费用和恢复能力，再与本地现状对比。
   当前暂无独立地区测点，也无两地同栈对照，不能据真实用户香港 API 摘要直接推导 S3 区域。
   改用其他区域或 CloudFront 前置须完成提案审查——**禁止两桶双写或跨桶漂移**。CDN 仍按
   冻结 ADR-004 不参与授权，本 ADR 不引入 CDN。
9. **实施顺序**：业务媒体平台先行（已有抽象、影响面小、可独立回退），Synapse 媒体库次之（需
   provider 兼容验证）。两步独立发布、独立回退、独立验收；任一步失败不影响另一步回退。
10. **可观测**：既有 storage 指标增加 backend 标签；S3 错误分类（5xx/限流/超时）计入既有错误
    码体系；桶容量增长与 GC 回收速率配对告警。日志不得含凭据、完整用户路径或明文内容。
11. **无 schema 迁移、无契约变更**：单一后端经配置切换，过渡期靠双读，不新增"每对象存储位置"
    列；OpenAPI 零变化、客户端零改动。若未来确需逐对象位置，另立 expand-only 迁移提案。
12. **覆盖范围必须逐路径核对**：`LocalBlobBackend` 只覆盖 `media/{user|e2ee|public}/…` 平台
    命名空间。旧头像、Moments/封面仍有 `LocalPrivateObjectStorage` 路径，worker 的
    `LocalPrivateAvatarReader` 直接读本地文件；它们不因增加 S3 四操作实现或 env 而自动迁移。
    本提案不声称已覆盖全部业务媒体。将这些旧路径纳入对象化前，须单列适配、读取授权、迁移及
    回退验收；Synapse provider 的本地缓存与删除/去重兼容另行验证。

**9月27日旧头像生命周期修正**：替换/删除头像的现有数据库事务同时登记 `identity.avatar.cleanup`
Outbox，先部署worker处理器再部署API发事件；退役对象在本地和S3同时删除，远端错误可持续重试。
私有对象key只在Outbox中，不放进幂等响应体；清理在数据库锁外执行，并保护当前头像引用。
旧签名头像URL读取前检查现有用户的当前头像指针，存储故障期间退役对象仍不可见，不改变token、
公开API或认证范围。提交失败不会先删旧文件。独立规格/领域后质量安全评审通过；相关7项新增病例
及86项受影响回归通过。真实PG并发与生产读回仍单独验收。

S3永久删除标记可阻止迟到PUT后的回读；若进程在写完后、标记复查前崩溃，可能留下不可读的密文
孤对象。启用前须证明恢复扫描/清理，不能承诺零孤对象或在回退时删除标记。

## 接口与兼容

- 新增 env（业务平台）：`BUSINESS_MEDIA_BLOB_BACKEND`、`BUSINESS_MEDIA_S3_REGION`、
  `BUSINESS_MEDIA_S3_BUCKET`、`BUSINESS_MEDIA_S3_PREFIX`、`BUSINESS_MEDIA_S3_ENDPOINT`（仅测试/
  兼容端点用）、`BUSINESS_MEDIA_S3_MAX_OBJECT_BYTES`；认证沿用 SDK 的 `AWS_SHARED_CREDENTIALS_FILE`。
- Synapse：`media_storage_providers` 配置进 homeserver.yaml 模板（render_config 管辖）。
- docker-compose：按实际实现给需要的服务传入上述 env；worker 直接本地读路径须适配后才支持 S3，
  不得仅增加 env 宣称完成。本地卷挂载保留（local 后端与过渡期回读需要）。
- 无 OpenAPI、无 schema、无客户端变更；`scripts/verify.ps1` 与 OpenAPI `--check` 必须零漂移。

## 验收与审查

- 单测：`S3BlobBackend` 对固定版本 S3 兼容服务的 put/get/exists/delete、原子写（写中崩溃不留半
  对象）、404→`MEDIA_BLOB_MISSING`、key 域守卫、prefix 逃逸拒绝；fake backend 覆盖限流/超时分类。
- 集成：隔离 PostgreSQL + S3 兼容服务全链路（上传/签名读取/引用释放/GC 回收/reconcile/审计）；
  双读过渡场景（S3 有/本地有/两边有/两边缺）矩阵；S3-only 新对象在兼容回退中可读、反向同步
  全量覆盖、在途上传与 GC 竞态、枚举游标中断续跑及 S3 孤对象重建；权限/超时/5xx 不触发错误
  invalidate；`chatflow_media_dedup` Synapse 套件在
  storage provider 启用下全绿。
- 门禁：`verify.ps1`、媒体三套件、OpenAPI `--check`、镜像 digest 固定检查。
- 生产（9月27日已授权，须满足门禁）：按 admin workflow——候选镜像 digest、切换前备份、写灰度观察、存量拷贝
  完整清单与 digest/长度校验、读 p95/失败率对比、回退演练（包含切换后新增对象；兼容 S3 读的
  限制单列，完全停用 S3 必须先反向同步并核验全量覆盖）。不能仅凭配置切回 local 宣称服务连续。
- 评审红线：领域审查确认隔离域/摘要种类/引用与 GC 语义零回归；质量/安全审查确认凭据与日志、
  桶不对外、删除只经 GC、E2EE 域无服务端新能力、无全球明文去重回归。
