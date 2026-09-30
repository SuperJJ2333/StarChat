# Outbox 消费契约与网关模板同步验证

本轮两项修复已完成生产发布和验收。Worker已补齐11个内部topic、146项精确消费者契约；固定原启动时间观察6045.611秒（约101分钟），374条真实新增事件全部PUBLISHED并有374匹配耐久回执，新增DEAD、FAILED及五类相关错误均为0，固定103056条历史DEAD完整行摘要不变。网关模板已同步，strict renderer退出0，香港/新加坡共12项严格TLS路由通过。完整当前运行配置及六份服务器私有快照已通过独立验收，API及44其他容器保持。旧工具VERIFYING及旧指纹失败记录保留，未重放或删除历史死信。下列更早条目为历史检查点。恢复入口见[任务记录](../workflow/tasks/2026-09-27-outbox-gateway-reconciliation.md)、[规格](../superpowers/specs/2026-09-27-outbox-gateway-reconciliation-design.md)和[计划](../superpowers/plans/2026-09-27-outbox-gateway-reconciliation.md)。证据统一在[本任务目录](artifacts/2026-09-27/outbox-gateway-reconciliation/)。

## 根因与边界

worker0e011固定镜像的只读SQL采用READ ONLY/REPEATABLE READ及超时。13:51UTC（21:51+08）按topic的快照有兼容后创建的当前DEAD **501=195兼容阶段+306 S3主写阶段**，全部为既有topic未注册接收端；431是上一批21:31的较早快照。调查中的口头601是合计笔误，原SQL rows正确，已更正。后续event_type快照是另一时刻，不与前一快照混成原子合计。无此次媒体cleanup失败。[只读根因报告](artifacts/2026-09-27/outbox-gateway-reconciliation/outbox-root-cause.json) SHA34469d83…。

持续主体是manual_reserve.published与wallet.funding_scan_discovered，生产者已在同一业务事务完成原事实、原审计及Outbox。新增接收端只追加内部耐久回执，不执行金融命令或发送通知。11个内部审计topic与43个直接生产源点已冻结，动态caller逐项核实，未知历史类型不得猜测。真正公告分发notification现场0事件，排除审计接收器；原9个handler和wallet.alert实际SMTP/receipt/Handover保留。历史DEAD、原错误和原审计保留，不重设PENDING或重放。

服务器nginx模板漏现网12行login broker/鉴权拒绝块，homeserver模板缺现网MobileLoginModule config={}。MAIN模板虽已有auth契约，却缺服务器已运行的iOS通话限流规则，不能直接用MAIN覆盖现网。候选由当次公开服务器模板及现网auth块派生，保持静态下载/cache/4k iOS入口/5r/s burst20限流、register403/admin404、TURN五条与S3。根因报告[gateway-root-cause.json](artifacts/2026-09-27/outbox-gateway-reconciliation/gateway-root-cause.json) SHAcd512df3…；nginx原镜像配置测试通过、挂载字节与宿主文件一致。

## 实施与测试检查点

- 新独立worktree `C:/Users/Administrator/.codex/worktrees/outbox-gateway-reconciliation/StarChat`，codex/outbox-gateway-reconciliation；972项当前源码输入、2848项额外验证输入及34项其它服务输入按SHA记录。主目录并行脏文件不被HEAD覆盖。
- 原行为基线：Outbox/Worker133 PASS、renderer10 PASS。依赖预检py3.12的pytest/SQLAlchemy/YAML/psycopg/FastAPI/httpx/argon2/boto3通过，Docker Compose渲染退出0；Ruff使用已安装0.15.22独立工具，不从py3.12缺失模块推断失败。
- 新实现先真实RED：5项因为缺worker装配/公共AuditWriter幂等接口失败。中间active GREEN样例一度把observation_id当字符串；按真实producer修正为整数及64hex source_identity后重新测试，旧GREEN只证明当时事务/装配，不作生产schema证明。动态schema以完整源而非口头摘要为准。
- Root独立回执测试22:17:02–22:17:03+08：17 PASS/exit0，包含真实PG唯一键并发、ACK丢失后的幂等重试、摘要冲突；writer与测试运行前后SHA完全一致。该检查点尚非最终发布签字，证据在独立worktree同名任务目录 `root-receipts-current.json/log`，后续回填。
- 临时PG16.9使用immutable本地image，独立合成数据库、tmpfs数据、只读root、专用Docker网络及127.0.0.1绑定，无生产数据/卷/凭据。初次internal网络不发布host端口，校验拒绝后按确定容器ID清理重建loopback fixture；首次启动即时ready失败、后续ready退出0，均保留原证据。完成后只清理本任务fixture。
- AuditWriter线上两个副本rawSHA afd549de…与MAIN 9c2ecfc…差异已证仅102个CRLF/LF；read_text和AST完整一致。发布CAS固定真实afd…，不放宽源码逻辑守卫。
- 网关模板与发布守卫测试先RED再GREEN，实现者42 PASS/Ruff PASS，工具SHA154ba1e0…，独立规格/安全审查进行中。候选nginx与现网逐字节相等，无须reload；homeserver全字段语义相等，仅格式同步，保留inode/权限/UID991且不重启Synapse。

旧基线pytest曾使用系统默认临时目录，后续所有测试显式使用本任务docs/verification目录下basetemp；不隐去此流程偏差。

### 22:56+08复审检查点（未发布）

最终六项Outbox源码/测试有185 PASS（含实际PG并发），独立规格/领域复审185 PASS，源码质量安全184 PASS/1 PG条件跳过并按同SHA复用真实PG证据。142个精确闭合契约覆盖250个非空生产者文件，未修改既有五项AuditWriter方法和金融生产者。九项归属源码/测试/模板已用[MAIN回填记录](artifacts/2026-09-27/outbox-gateway-reconciliation/main-source-integration.json)先全部CAS再复制。

旧网关工具154版被安全审查拦住：YAML数字/布尔key会与字符串混同，Synapse实际配置挂载未强制验证。82eb版已补类型比较与实际/data/PID1/mounted SHA守卫；新增9项RED后66项组合focused PASS，规格复审通过。直接生产CLI仍报运行两次快照不相等，导入assessment调用PASS不能替代直接入口，此运行门禁继续诊断，未prepare/publish。

旧Worker发布工具另被复审发现postprobe复核、私有目录祖先/持锁FD身份、Linux生产者扫描空跑三项缺口；正在修复并保留旧阻断记录。副本测试明确适配实际Linux源码路径且非空扫描，原仓库测试字节保留。22:50:38的真实只读兼容快照[762条结果](artifacts/2026-09-27/outbox-gateway-reconciliation/worker-release-live-validation-result.json)未截断，两活跃契约全部合法，4条invalid只有既有DEAD，未执行任何回执或重放。

完整verify的第一次缺开发.env，第二次缺当前第三方Synapse源码且根data junction导致容量路径安全测试失真；失败日志均保留。验证环境现用合成开发.env、普通data父目录与四个生成子目录的artifact junction，另冻结12项当前公开第三方文件。第三次已通过493基础设施、28推送桥、9 Matrix Bot测试，业务及其后阶段仍在运行；推送桥的两条既有依赖弃用警告原样保留，不作全绿结论。

## 发布前与验收要求

实际API已由另一任务在13:44UTC后变为e3043e9a…；本任务只发布worker，保留最新API。当前worker Compose含旧API pin，发布工具须投影为仅worker并严格比较其完整配置，绝不将旧API一起up。S3 SDK/凭据RO/媒体父只读+avatars子可写、PHONE、原9handler、schema0090及其它容器均保持。发布工具默认只准备；Root在先规格/领域后质量安全审查、聚焦及完整verify后执行。

生产结论须基于严格renderer check exit0、实际TLS安全路由、新事件耐久回执与成功状态、跨过10分钟reaper宽限后的无对应新增缺消费者死信；不得以healthy、旧DEAD总数或仅合成样例替代。尚未执行历史事件重放、金融写入、SG迁主区、设备体验验收或新客户端发布。

## 2026-09-28发布准备检查点

- 网关实际prepare/publish通过，最终工具9f9d34…及两模板7d4b717…/dd81513…冻结；nginx字节保持、homeserver仅格式变化、全字段类型语义保持。nginx -t及真实renderer check均退出0，无reload/restart，见gateway-publish-stage.json。00:08+08再次实际check确认NO DRIFT。
- 真实只读旧候选校验发现4条继承好友审计调用未纳入原142契约。最终追加4个精确契约，以实际producer→Worker链路5RED→GREEN，MRO22调用/20动作闭合，最终146契约及相关409PASS，无业务producer改动；独立源码规格7a314…/安全e86d…通过。最终catalog409915…与测试1a4e…按CAS回填。v3实际只读951/953行均合法，原4DEAD未重放，见worker-release-v3-live-validation-result.json/provenance-result.json。
- 完整verify第三次3242PASS/93skip/1旧worktree OpenAPI包输入失败；冻结当前四个packages后5契约PASS，冻结当前frontend后移动127PASS/1skip，全部余下强制阶段通过。原exit1及其它环境失败留存，按变更影响规则复用未变输入；最终146纯catalog差异由409专项及独立70源码测试覆盖。见mandatory-verification-impact-closure.json，不宣称原verify脚本exit0。
- 观察器旧版本在600秒宽限之前错误地优先返回等待。8RED→24GREEN；最终489466…先拒绝死信、回执冲突/缺失、非法信封、历史变更或截断，SPEC72c39…及QSe6695…通过。固定实际StartedAt、只读事务及600秒双真实事件回执门禁保持。
- Worker首次prepare于23:51:49–23:51:55+08被严格守卫拦住，未build/up；timer finally恢复active/enabled。只读诊断0494…证实FROM、四COPY及所有hash一致，JSON排序改变expected COPY顺序。最终driver c223e5…只改两行按固定CHANGED_PATHS迭代，真实v3 golden旧版失败→新版通过，67工具测试通过，7类重新计算digest的非法Docker指令仍拒；包3bb5…/manifest e5a1…保持不可变。独立delta SPEC6d50…通过，安全审查进行中；复审及实际Linux候选通过后才切Worker。

历史集合固定103056条DEAD，完整行摘要b6fba67…，仅服务器私有目录存ID；原v2固定集合完整行另行证明保持，未清理或重放。此有限固定集合不代表发布前全部历史死信总量。

## 实际上线及有限观察（2026-09-28 00:45+08）

第三次prepare实际PASS，candidate a5087d…、9940源库存只有四项变化，新文件+1。隔离Linux实际cwd/main/siteAudit正确、241producer文件/65enqueue非空扫描、11新topic及原9handler、S3 SDK保持，synthetic tests exit0，无productionDB/main/maintenance调用。启动器edf26…规格f5b1…→安全24c570…通过；此前COPY误报和import路径失败均保留，各自修复，不改v3包。上次失败IID root600/8b1e…已精确归档，原image保留。

仅Worker于16:34:17.650014697UTC（00:34:17+08）切至a5087d…/aed406…healthy。旧发布journal为VERIFYING：完整rawruntime指纹不匹配，自动回退也因相同完整guard拒绝，实际未回退。候选实际source、private配置image-only及44其它容器保持，API e304/5e43健康；但旧阶段仅存opaquehash，无fullInspect可逆恢复，712默认/4005Env交换等有限反证无命中，无法断言该hash相等或精确差异字段。原失败记录明确保留，另用完整frozen配置→currentruntime语义验收、独立复审与新私有完整快照闭合，不覆盖旧journal/hash、不移动窗口。

固定原StartedAt的[675秒观察](artifacts/2026-09-27/outbox-gateway-reconciliation/outbox-postrelease-fixed-window-result.json)为PASS：active reserve21+funding discovery22共43PUBLISHED，43完整确定性回执匹配；FAILED/DEAD/invalid/missing/conflict/overdue/PROCESSING/PENDING均0、未截断，五类相关log标记0。103056条原固定DEAD完整行摘要b6fba67…不变，无重放/观察器receipt写入。此结果是当次有限窗口，不能推断未来无错误或历史全DEAD清零。

[公网实际验收](artifacts/2026-09-27/outbox-gateway-reconciliation/public-http-post-result.json)于16:42:57UTC：香港/新加坡共12严格TLS路由全部符合200/403/404，strict renderer exit0；API、Worker、两Synapse healthy/restart0，API身份原样保持。初次只读探针误用syncworker容器名导致CalledProcessError，按实际inventory修正为starchat-synapse-sync-worker-1后复测通过，原失败log保留。临时PG与两精确自有网络已清理、loopback54836关闭，见local-fixture-cleanup.json，未清理生产数据或镜像。

### 延长观察与独立运行验收政策（01:05+08）

固定相同StartedAt的[延长观察](artifacts/2026-09-27/outbox-gateway-reconciliation/outbox-postrelease-extended-window-result.json)于17:05:54UTC通过：1889.596秒、116条真实事件（两类各58条）均PUBLISHED并有116匹配回执，新增失败/DEAD/相关错误为0，103056条冻结历史完整行摘要仍相同。观察器不执行数据库写入或历史重放。[再次公网检查](artifacts/2026-09-27/outbox-gateway-reconciliation/public-http-final-before-runtime-result.json)于17:05:40UTC仍12TLS路由通过、strict renderer0、API身份保持及四服务healthy/restart0。

Root逐项阅读并明确接受独立[当前期望策略](artifacts/2026-09-27/outbox-gateway-reconciliation/worker-runtime-desired-policy.json)（e8f777…），[授权](artifacts/2026-09-27/outbox-gateway-reconciliation/worker-runtime-root-policy-authorization.json)与领域审查补充分别记录。这是当前完整运行配置验收标准，不是旧容器相等证明；原VERIFYING及失败opaquehash保持。冻结17项Config、64项HostConfig、全挂载/标签/网络闭合规则，未知键或类型差异直接失败。image ArgsEscaped=true，runtime键缺省必须保持缺省，不使用早期设计中的false推测。固定版本Moby/Compose公开源码与SHA另存[runtime-primary-sources/manifest.json](artifacts/2026-09-27/outbox-gateway-reconciliation/runtime-primary-sources/manifest.json)；仅支持来源解释，不替代独立策略批准。新工具完整TDD、独立源码SPEC→QS及实际私有快照/标记验收尚待完成。

纯函数规格预审指出还需独立核对顶层实际Path/Args及daemon应用的AppArmor/SELinux标签。Root明确批准[补充期望策略](artifacts/2026-09-27/outbox-gateway-reconciliation/worker-runtime-effective-process-policy-authorization.json)（4dd2f111…）：argv由预期Entrypoint/Cmd推导，AppArmorProfile精确docker-default，ProcessLabel及MountLabel精确空字符串。Root仅白名单读取这五项，实际python/[main.py]及三个profile与政策一致；不读取Env、不改运行配置。作者须补独立校验及负例测试，最终SPEC→QS要求仍保持。

首次完整工具dd7b/测试356d在16专项与44既有工具测试通过后，被独立[最终SPEC](artifacts/2026-09-27/outbox-gateway-reconciliation/worker-runtime-semantic-acceptance-spec-review.json)（35488e9d…）拦截：post-marker检查若因marker权限/owner或祖先边界改变失败，原退休函数会被同一普通private检查再次拒绝，遗留canonical成功标记。独立复现三条失败链；该版未用于生产，也未上传执行。原源码/测试/验证记录按精确SHA归档，修复须以已持有目录及marker FD精确绑定本工具文件退休，拒绝外来替换，并重新SPEC→QS。此记录不改写为首次通过。

[一小时观察](artifacts/2026-09-27/outbox-gateway-reconciliation/outbox-postrelease-hour-window-result.json)于17:38:21UTC通过：3836.795秒，两个活跃事件各119条，共238PUBLISHED/238匹配回执，新增DEAD/FAILED/无消费者/非法信封/回执缺失或冲突等均0，固定103056条历史完整行摘要不变，扫描未截断。新验收工具的修复不涉及业务源码或服务重启，仍固定16:34:17.650014697UTC起点。

17aa修正版20专项/44既有测试及Ruff通过，独立[SPEC复审](artifacts/2026-09-27/outbox-gateway-reconciliation/worker-runtime-semantic-acceptance-spec-rereview.json)（9135022a…）通过原三失败链修复。[首次QS](artifacts/2026-09-27/outbox-gateway-reconciliation/worker-runtime-semantic-acceptance-quality-security-review.json)（7f4f1c7c…）仍拦截一个临时文件清理窗口：临时路径被替换或unlink失败时，不能让其清理拒绝阻止退档本工具已创建的canonical标记，也不能删外来临时文件。其余完整配置/CAS审查通过；该helper仅上传，未执行生产验收。再次最小修复、独立delta SPEC→QS和真实Linux隔离探针通过后才执行。


## 最终现场验收（2026-09-28 02:15+08）

54360修正版补齐临时文件归属判断与独立canonical退档，23专项/44既有测试及Ruff通过，独立SPEC 2f9bb6ad与QS e68a38eb通过；Root实际Linux隔离8case探针通过。随后只读完整配置验收拒绝两项Compose标签预期值，未执行accept、未保存成功标记、未改变服务。Root白名单字段诊断仅输出字段名；按固定v2.40.3公开源码确认replace采用service-name-number，version采用semver Core，完整CLI包版本守卫仍保持。新增[两标签源清单](artifacts/2026-09-27/outbox-gateway-reconciliation/runtime-primary-sources/compose-labels-manifest.json)保留旧源清单。

最终helper47bb03f9、tests5ff8a8ee、probe7e4b4900仅修改两项生成标签预期值，其余28函数/类AST不变；24专项/44既有测试通过。独立[规格复审](artifacts/2026-09-27/outbox-gateway-reconciliation/worker-runtime-semantic-acceptance-spec-compose-labels-review.json)35473599先通过，再由[质量安全复审](artifacts/2026-09-27/outbox-gateway-reconciliation/worker-runtime-semantic-acceptance-quality-security-compose-labels-review.json)4ac4f5d1通过。Root重新执行[最终Linux8case隔离探针](artifacts/2026-09-27/outbox-gateway-reconciliation/root-runtime-linux-final-probe-result.json)PASS，无生产操作。

Root[只读全字段检查](artifacts/2026-09-27/outbox-gateway-reconciliation/root-runtime-readonly-final-result.json)通过CURRENT_DESIRED_CONFIG_MATCHES后，仅执行一次[独立验收](artifacts/2026-09-27/outbox-gateway-reconciliation/root-runtime-accept-final-result.json)，结果ACCEPTED_BY_FROZEN_CONFIG。它证明固定当前Compose/镜像及明确批准策略与当前运行配置一致，不恢复已删除旧容器的Inspect，也不声称旧指纹相等。原state.json SHA7fc06744与VERIFYING保持；六份完整Inspect/image/network/effectiveCompose快照及新acceptance.json保存在服务器私有desired-runtime-acceptance目录，未下载私密内容。

[独立metadata复核](artifacts/2026-09-27/outbox-gateway-reconciliation/root-runtime-acceptance-metadata-result.json)为METADATA_VERIFIED：marker SHA c4ea05389ec8dfb63df01f4278f225c3101fbc6028228fd246ea81a0bd3c2c26，六个快照摘要全部匹配，文件root:root/0600、目录0700，固定a508/aed/原StartedAt及工具/两政策/原journal绑定正确。完整配置验收过程无重启、无数据库写入；既有标记不再重复accept。

[最终真实观察](artifacts/2026-09-27/outbox-gateway-reconciliation/outbox-postrelease-completion-window-result.json)于18:15:12UTC通过：6045.611秒、reserve187及funding discovery187，共374PUBLISHED/374匹配回执，新增DEAD/FAILED/PENDING/PROCESSING/非法信封/回执缺失或冲突/超期及五类日志标记均0，扫描374未截断。固定103056条历史完整行摘要b6fba67b仍相同，数据库REPEATABLE READ/READ ONLY，schema0090、未重放。结论限于该观察窗口，历史DEAD仍保留。

[最终两地公网复核](artifacts/2026-09-27/outbox-gateway-reconciliation/public-http-completion-result.json)于18:14:54UTC通过：12项严格TLS路由全部200/403/404符合预期，renderer退出0，API身份保持及API/Worker/两Synapse healthy/restart0；监控timer最终active/enabled。网关模板发布无需nginx reload或Synapse restart。409业务专项与真实PG幂等/并发、网关69专项以及独立规格→安全审查通过；完整verify原exit1及补齐当前输入后的强制阶段闭环继续按mandatory-verification-impact-closure.json保留，不冒称原脚本exit0。

最终现场证据先经[独立领域复核](artifacts/2026-09-27/outbox-gateway-reconciliation/root-final-production-spec-review.json)（6ee7b52e），再经[质量安全复核](artifacts/2026-09-27/outbox-gateway-reconciliation/root-final-production-quality-security-review.json)（128c54c4），均PASS_WITH_EXPLICIT_HISTORICAL_LIMIT、无阻断。结论仅覆盖当前部署批与约101分钟真实观察；没有长期稳定性、146项契约全部实际发生或历史运行指纹相等的声明。源码、工具、审查、实际阶段和归属文档最终摘要见[root-final-reviewed-inputs.json](artifacts/2026-09-27/outbox-gateway-reconciliation/root-final-reviewed-inputs.json)，其早期launcher摘要已按原SHA另外保留。当前任务完成。
