# 边缘/TURN与S3部署

## 恢复入口

- 目标/授权：用户明确“请你部署边缘/TURN服务和s3多媒体文件存储。优化使用体验”，并要求扩盘vs数据库性价比。授权分批部署现有方案；不迁主区/不购买RDS/不清理本地或改金融/E2EE。
- [计划](../../superpowers/plans/2026-09-27-edge-s3-deployment.md)、[ADR0086](../../adr/0086-media-storage-s3-backend.md)、[AWS输入](../../verification/2026-09-27-edge-s3-aws-access.md)。
- 当前：AWS输入均验证；SG边缘/TURN及HK五条候选已上线。业务1aa6/0e011于20:14 S3主写上线，保留PHONE-only修复及本地fallback；切换后新鲜三类扫描COMPLETE，108对象33,696,190字节远端校验、本地保留。Synapse996两进程19:44三阶段同步S3写上线，21:21:30历史有限扫描完成：43批全部PASS，2800复制/96再校验，累计881,098,438字节（含重复校验，不当作唯一容量）。21:22权威快照2923有效对象全部匹配S3路径/大小，缺失/大小不符/有效对象fence均0。最终监控timer enabled/active、service Exec0、OK/alerts0；四服务healthy/0restart。
- 最后更新2026-09-27 21:35+08。本批部署及当次有限存量验收完成，整体健康保留ATTENTION。回填loop session60854已经退出0，不再次启动旧游标。最终只读Outbox分类21:31快照：兼容后创建的DEAD431（兼容195/S3主写236），全部是已存在主题未注册消费者，实际错误标记精确匹配；媒体cleanup incomplete/failed/dead及已注册handler新增DEAD均0。不得说只是历史记录；后续需独立修复消费者契约，不重放金融/未知事件。原有renderer漂移不全量覆盖。下一步为客户端真实附件/ICE、Native IPv6及7–14天区域观测日志验收；不能宣称用户体验提升/迁主区。独立worktree sg-edge-s3基线b9eca8a4。

## 验收台账

| ID | 预期 | 实现/测试 | 生产/缺口 |
|---|---|---|---|
| E01 | 无状态SG L4，SNI限定/未知拒绝，HK安全路由保持 | 运行healthy/0restart；公网JSON200/register403/admin404/未知SNI拒绝通过 | 已部署独立入口；不导流正常API，可信IP链待验收 |
| E02 | UDP/TCP TURN双向中继/鉴权/私网拒绝/配额 | 实际公网双向Send/Data与ChannelData、过期鉴权拒绝、私网/元数据拒绝、8成功/第9次配额拒绝通过 | 已上线固定4.13.1，无持久卷；两传输公网验收通过 |
| E03 | HK模板追加候选，旧HK保留，回退可执行 | 准备与发布脚本独立规格/安全通过，精确URI语义差异守护 | 18:43已公布SG UDP/TCP两个URI；原HK三条保留，24其他Compose容器不变 |
| S01 | 业务/旧头像朋友圈/worker字节存S3 | 219受影响测试、实际Linux API55/worker52，PHONE基线23专项及独立双审查通过；OpenAPI324路径不变 | 20:14 S3主写上线，API1aa6/worker0e011 healthy，23其他容器保持；无认证生产上传会话 |
| S02 | GC/分页reconcile/幂等迁移/故障/兼容回退 | 有界DB守卫迁移与Outbox头像清理、真实PG两种锁序；postflip9测试及独立审查通过 | 切写后fresh三类扫描COMPLETE：23头像/85朋友圈33,696,190字节远端再校验；本地及metadata保持，监控已恢复 |
| S03 | Synapse S3 +共享引用/补偿/退役删除一致 | 实际Synapse/PG/Redis多worker/崩溃fence/恢复/PUT-GC竞争；author100/independent95，driver6及额外16断言、最终覆盖独立17测试通过 | 19:44两个996进程同步S3写上线；43批有限扫描完成，21:22当次2923有效对象路径/大小全匹配；本地保留，不称未来/所有用户媒体或GC全面验收 |
| C01 | 基于官方实时价格与真实容量推荐 | SG官方目录核验完成；HK根218G/可用140G/33% | 当前不增盘或购RDS；仅容量则gp3更便宜 |

## 当次基线和时间

- 14:48前后HK实际API e880ec8ed2dd（healthy）、worker15659d6c20a4、Synapse/syncfd9d961a472a；27其它现有容器含其它项目与隔离PG，禁止重建。
- SG私网172.31.46.134/public13.229.60.153/securitygroup sg-057b9653a9a140598；仅sshd/时钟/DHCP监听，无Docker/主机防火墙服务。root已在线扩至39.93GiB，原快照保留。
- 14:52:59+08 AWS查询实例/EIP/SG/S3/DNS全AccessDenied；IMDS仅读取身份不读取凭据。证据[aws-preflight.json](../../verification/artifacts/2026-09-27/edge-s3-deployment/aws-preflight.json)。
- 调查/并行实施起点约14:48；具体工具起止与真实退出码继续填入验证报告，不以聊天假设计时。

## 16:34阶段历史交接（由恢复入口及后续实际发布更新覆盖）

本批仅部署独立边缘nginx与创建私有SG桶；未启用TURN、迁移生产媒体或修改香港配置。不得把桶/源码候选视为媒体已经使用S3。原API诊断协议6033保留；正式切换前再次核对现网镜像和源码，不继承旧镜像快照。

## 2026-09-27 16:34+08 执行更新

用户已配置maintenance策略、DNS与秘密；实际实例网络权限/DNS生效，NACL/IGW通过，EIP查询为空。
HK秘密字段齐全但身份InvalidClientTokenId；准备增加仅指定秘密PutSecretValue，以安全复用HK TURN。

E01定向边缘nginx已部署/公网JSON与既有403/404/未知SNI门禁通过；正常API未切流、可信客户端IP链仍待验收。
S01单个SG私有桶已建并真实HTTPSCRUD验证；业务/Synapse源码候选通过，生产媒体尚未启用/迁移。
E02/E03等待固定EIP、秘密安全源和公网中继。S02真实PG并发两种锁序已通过，最终业务receiver漂移保护合并中；
S03真实AWSprovider字节/删除/回退通过，但完整Synapse/PG多worker和恢复/迁移门禁仍缺。
完整verify原1个fixture失败保留且复测闭环；未变输入余下门禁已通过，证据复用不重跑36分钟门禁。
当前API/worker/Synapse现网镜像16:31复核仍原e880/15659/fd9d且healthy，香港未变更。

[验证报告](../../verification/2026-09-27-edge-s3-deployment.md)包含实际证据和缺口。
下一可执行动作：完成受影响源码回填/契约检查；用户补EIP/有效身份/新策略后，先刷新云端事实，
读取Secret Manager到服务器受保护SDK文件，TURN公网验收后模板追加，媒体按独立门禁启用。

## 2026-09-27 18:12+08 恢复点

用户提供的三项云端缺项已闭环，无需再提供配置：EIP绑定同一实例且DNS一致；SuperJJ STS账户正确、两个媒体前缀CRUD/严格404通过；限定PutSecretValue生效，秘密经原生SSH加密管道更新/读回，AWS字段保持。旧13.229地址只用HostKeyAlias复用既有可信主机密钥，不关闭验证。

E01新EIP定向TLS/JSON200/403/404/未知SNI复核通过。E02容器启动、仅必要能力/临时卷/日志封顶/41中继端口已落实，尚未公布客户端候选。旧配置的裸`::`被coturn解释为地址通配并误拒绝公网；TDD修复及固定4.13.1候选14测通过，实际双向中继通过，但私网拒绝一项仍调查中。验证器3项独立P2已RED→GREEN，新增ChannelBind/ChannelData四项RED→GREEN，合计15项通过；实际完整公网门禁仍待。不得把启动状态作为E02完成。

S01/S02业务监控5文件经SHA保护回填，72专项与Ruff/契约检查通过；接口与136表ORM定义不变。S03实际Synapse+2媒体worker+PG/Redis的10阶段全部通过，包含共享引用、备份恢复、删除/发布失败重试、兼容回退与延迟PUT后进程崩溃；fence使孤对象不可读，暂停写入后的DB守卫恢复已证明，尚无自动生产清扫器。合成对象/容器清理通过。

香港18:09基线API e880ec8e、worker15659d6c、Synapse及synapse-sync-worker fd9d961a均healthy；API/worker实际UID0，Synapse主PID991，sync UID0。worker导入site-packages/app，必须覆盖真实路径。尚未部署业务/Synapse媒体或迁移；main候选含另任务未批准启动诊断，不得整体发布。香港网络延迟、真实元数据清单和精确源覆盖在独立准备中。

## 2026-09-27 18:58+08 恢复点

E02/E03已完成：固定coturn4.13.1采用单值external-ip，修复隐式私网白名单及裸IPv6零地址通配；真实公网UDP/TCP双向ChannelData及配额通过。18:43:35+08香港仅重启原镜像Synapse以追加SG两条TURN URI，24其他Compose容器保持；18:57新EIP定向TLS ready200/register403/admin404/未知SNI拒绝再次通过。没有生产用户账户，因此没有宣称认证后的客户端TURN接口或真机通话验收。

18:45两个生产PG自定义dump完成，并在隔离网络的新PG16.9实例恢复：业务138表/head0090_friend_discovery_index，Synapse168表，均一致。备份仅保存在服务器0700目录，未改生产数据库。香港S3小对象20次实测PUT p95约139.55ms、GET含正文p95约78.25ms；这不是大文件或真实用户体验结论。只读盘点业务候选头像23/朋友圈85、Synapse2526条本地元数据，源字节继续保留。

业务兼容镜像已实际构建并独立Linux验证：API55ac98e2、worker0e011134；只覆盖live中14/15个公开路径，实际OpenAPI324路径SHA与旧镜像一致，不部署另一任务未批准的启动诊断route。兼容compose已私有冻结为local_s3_read，worker仅新增avatars子目录可写，其他媒体仍只读；受保护SDK文件只读绑定，无AWS密钥进入Docker环境。尚未执行兼容发布器。

Synapse runner6db3c4df已独立规格及安全通过；作者相关100测试、独立95测试范围不同分别记录。真实PG/Redis、公共FileResponder、PUT与跨worker删除竞态通过；legacy摘要隔离守护、审计先于游标、超大对象不推进游标已闭环。生产迁移仍需实际writer/Redis新鲜证明，不可把单批结束视为全量完成。

## 2026-09-27 19:10+08 兼容发布门禁修复

首次worker发布在启动门禁失败：准备脚本将S3 prefix写为`business`，实际后端要求`business/`。发布器120秒门禁后恢复旧worker并healthy，API未切换、未迁移生产媒体。失败证据保留，不把它改称成功。修正前实际候选配置隔离重现失败，修正后两候选真实Settings、后端构造和SDK凭据文件读取全部通过；无DB访问、无S3请求、无HTTP启动。可选endpoint显式unset，避免空字符串传SDK。

v1私有before/candidate保留原路径以维持回退容器Compose标签引用；新准备使用独立`business-compatible-v2`，只前缀/可选endpoint修正和发布前增加隔离配置门禁。源镜像55ac/0e011不变。新增Synapse runner与测试按冻结SHA回填，Dockerfile/apply_patch只补runner复制；主目录相关97测试通过。业务迁移驱动13独立测试通过，服务器上传SHA一致；待两兼容服务healthy后先执行三类dry-run。

## 2026-09-27 19:29+08 兼容发布及业务baseline完成

19:19:36–19:20:17 v2兼容发布PASS：worker0e011与API55ac各自healthy、0restart，实际15/14来源文件SHA、Settings/backend/SDK文件门禁通过，23其他Compose容器保持。严格TLS ready及Matrix版本JSON200、register403/admin404、network diagnostics和friend search401全部通过，324路径OpenAPI SHA与旧live完全一致。

发布后日志总体ATTENTION保留：worker持续未注册consumer汇总，没有新handler死信/maintenance/storage错误。只读Outbox聚合：102117条DEAD创建于本次切换之前，切换后DEAD0；头像cleanup未完成/失败/DEAD均0。此为原有告警，不能假称无错误或擅自重放金融/历史事件。

三类dry及baseline enforce均COMPLETE：platform0；avatars扫描58/跳过35/拷23，校验5,260,105字节；moments扫描108/跳过23/拷85，校验28,436,085字节。数据库元数据无变更、本地字节无删除；baseline不等于切写后的最终全量覆盖。私有PENDING/audit/checkpoint和聚合证明留服务器。下一步安装真实有界容量/只读GC配对采样及本地告警，切两服务s3后开启新的checkpoint轮次再扫描。

## 2026-09-27 19:42+08 切换及监控恢复点

真实媒体监控首轮PASS：当前108对象/33,696,190字节，S3权限/凭据/超时/平台GC错误0；SDK有界容量probe393ms。每五分钟systemd timer已安装、service Exec0，私有聚合台账和本地告警；GC配对只涵盖business/media/的platform enforce统计，不宣称legacy或Synapse完整回收字节、真实用户请求延迟或外部通知。切换窗口暂时停止timer，结束后必须恢复。

业务S3写首轮两服务S3模式/健康/后端构造均PASS，但其他容器门禁失败，自动恢复两服务same-image local_s3_read。根因是inventory使用docker ps -q短ID，而排除目标用64位完整ID，误将本次替换算为其他容器；不能把此轮写为完成。独立作者正在增加RED→GREEN并修复重试路径；旧私有before留原路径，保持回退容器Compose标签有效。后续需新一轮三类dry/enforce，不能复用已完成游标冒充fresh scan。

Synapse996镜像实际build/auth9个来源/SDK/import/Config与17+1层通过，私有prepare及真实Redis/PID/maintenance无后台职责通过；publisher ca7d独立规格/安全通过，已开始三个阶段，每阶段仅sync/main。首次provider仅在两进程都有新生命周期后write=false；两个兼容provider已加载才启用远端写。没有自动执行存量backfill。

完整renderer只读检查仍exit1：homeserver仅既有modules语义漂移，worker/element一致；nginx有既有实质模板漂移。证据保留，本批只按已冻结live增量安装provider，不覆盖网关/auth规则，不声称全renderer clean。

## 2026-09-27 19:57+08 真实发布与并行漂移

Synapse三阶段生产发布实际PASS（19:43:14–19:44:10）：bootstrap_image→compatible_provider→synchronous_s3，每阶段先sync后main，均为99643e45固定镜像；27其他Compose容器保持、TURN五条及原模块保持。两个媒体进程均具生命周期守护及S3同步写能力，尚未执行存量PUT。生产回填assessment于19:55拒绝两个进程的全配置namespace hash，先前源码/provider/Redis/replication门禁通过；正在只读定位连接池设置与实际数据库/Redis权威是否相同，不放宽到未证明命名空间。

业务S3重试cf3源及7回归通过，尚未切换。新鲜baseline启动时镜像守护发现独立PHONE-only任务已经发布1aa6c222（worker仍0e011），正确拒绝而未执行迁移/切换；正在独立核对新像继承的S3源码及当前Compose。不得用旧55ac覆盖用户已批准手机号修复。首轮checkpoint已保留为服务器private/cli-state-first-baseline，后续新扫描尚未完成。定时监控仍按发布窗口暂停，必须在切换完成或停止切换后恢复。

19:57+08通过香港到新加坡EIP的定向严格TLS复验：ready JSON200/register403/admin404/未知SNI拒绝；最新21:26再次复验的[证据](../../verification/artifacts/2026-09-27/edge-s3-deployment/final-edge-eip-public.json)。所有AWS输入已闭环；本段为当时发布守护与配置语义核对状态，不需用户补新权限。

## 2026-09-27 21:35+08 本批交付与后续边界

S01/S02业务新写与切写后有限扫描完成；S03 Synapse新写、43批有限扫描及最新2923有效对象路径/大小覆盖完成；E01/E02/E03边缘和TURN配置、公网中继、候选发布与最终运行/TLS通过。原本地字节、数据库恢复备份、fence及同镜像兼容回退保留。没有迁主区、购RDS/扩盘、执行生产GC或发布startup API。

部署及维护源/镜像均有冻结SHA与实际Linux/PG/多worker门禁。最终worker健康报告ATTENTION不是S3处理器失败：21:31只读分类431条新创建DEAD为已有主题无消费者；9个实际注册handler包含媒体cleanup、当前真实handler失败0。probe中间SQL保留字别名失败被关闭，event_window最小修正1 RED→7 GREEN及根独立7 PASS/规格→安全闭环，无生产写。新建消费者/修复投递与历史重放属于另一个有界任务，金融状态不得推导或补写。

最终证据：[完整验证](../../verification/2026-09-27-edge-s3-deployment.md)、[43批摘要](../../verification/artifacts/2026-09-27/edge-s3-deployment/synapse-backfill-completed.json)、[DB→S3快照](../../verification/artifacts/2026-09-27/edge-s3-deployment/synapse-snapshot-coverage.json)、[最后监控](../../verification/artifacts/2026-09-27/edge-s3-deployment/media-storage-monitor-final.json)、[实际HTTP指标](../../verification/artifacts/2026-09-27/edge-s3-deployment/media-process-final-live-metrics.json)、[Outbox分类](../../verification/artifacts/2026-09-27/edge-s3-deployment/final-outbox-provenance-readonly.json)。计数和样本有各自时间与范围，不能将不同快照相减作为泄漏/改善证明。

后续发布必须以当前API1aa6/worker0e011/Synapse996及实际Compose标签做最小覆盖，保留PHONE及S3，详见[实际回退](../../runbooks/singapore-edge-node.md)。外部验收待真实使用日志：附件上传/下载、ICE relay和原生IPv6、国家/运营商/峰值分层、7–14天HK/SG可比窗口。现有单API进程SDK窗口不足以选主；全renderer既有modules/nginx漂移不得覆盖。本地旧字节清理需独立观察和恢复验证，当前香港根盘富余不需要购买容量。
