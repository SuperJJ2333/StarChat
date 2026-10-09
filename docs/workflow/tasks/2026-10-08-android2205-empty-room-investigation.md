# Android2205空列表/无法入房：回退后独立调查

用户当前授权：“先立刻回退、发布0.4.37，之后解决问题”。[紧急回退](2026-10-08-android2206-emergency-rollback.md)已完成；[调查计划](../../superpowers/plans/2026-10-08-android2205-empty-room-investigation.md)。22:01–22:04+08开始实际只读调查。源码c628fe2e/原故障成品b71e8394…ecf9，history-icons-performance-2204 managed；不得把已恢复2206当2205修复已完成。

所有权：本调查文档/证据及未来明确失败用例；当前无产品或生产写入。[证据](../../verification/artifacts/2026-10-08/android2205-empty-room-investigation/)。只导出账号绑定枚举聚合，原始日志/身份ref/密钥/消息/token未落盘。

## 已取得证据

- 22:01:23+08账号a1014826460近1h有14批Android0.4.36+2205诊断。soft_kick timeout14/slow14，hard_restart timeout11/slow3；没有framework异常，不能认定没有挂起或手机OOM。
- 22:01:26+08账号绑定近1h最多各70000行：sync13次200，p95 351ms/max471ms；business other200×30/401×4、Synapse other503×1等保留。三容器无OOM/restart。这是匹配到的有限样本，不证明全部网络正常，更不证明手机进程未崩。
- 22:04:45+08实际stage/result投影（`account_phases.json`，修正旧聚合脚本读outcome而DTO真实字段为result的分类局限）：2205 sync4次expired都已到sync_response_received，仍未到sync_processing_done，观察最高300997ms；chat_list_load1次expired到route_enter/cache_load_started/first_frame_rendered，最高300000ms；conversation_open28次expired（23只有user_action，5再到identity_lookup_done），最高45998ms；9次cancelled已timeline_local_started/首帧而无local_timeline_ready。partial不是失败请求数量，不能将多次checkpoint当不同操作失败数。
- 同一账号最新2206出现conversation_open success1次2865ms及matrix_sync success1次2234ms，均包含local_timeline_ready/content_ready及sync_processing_done/cleanup；这是服务器收到的单次客户端诊断，支持回退后实际有成功案例，不等于USB/全部房间或更新弹窗真机验收。
- 源码边界：新TimelineIdStore首次prepare/旧索引迁移加入SDK原集合门；worker另开SQLCipher连接，ACK前源码明确blob_close，故不能仅凭“两个连接”就宣称持锁死锁。同步响应后处理与本地加载await为优先范围，但具体哪条await/根因未证明。

## 验收/下一步

| ID | 要求 | 当前状态 |
| --- | --- | --- |
| TRACE | 用户故障对应版本与阶段证据 | 账号2205聚合/partial闭合阶段已取得 |
| ROOT | 具体未结算await及实际RED复现 | 尚未完成；不能称已定位索引死锁或OOM |
| FIX | 保数据最小修复与平台证据 | 未实施；2206仅回退 |

下一可执行步骤：用exact c628构建测试夹具，跟踪sync_response_received后数据库集合门、timeline prepare/migration reader及账号恢复等待；添加可控阻塞的旧数据库升级+并发sync/入房用例，确认可用Android测试设备/模拟器及其签名/数据边界，仅用合成数据复现。没有USB手机这一约束不阻塞代码/模拟器定位，不能假称读取用户手机堆栈。iOS登录调查继续独立。

阶段时刻来自三个capture receipts及phase receipt；22:04首次phase远程__file__不适用失败已改为内嵌只读lookup并成功重跑，不影响生产。无新隧道、运行构建或产品改动。

## 2026-10-08 23:46+08 源码调查与候选（未发布）

用户继续授权排查并解决2205；当前稳定2206回退渠道未改。隔离managed工作树：`C:/Users/Administrator/.codex/worktrees/android2205-sync-deadlock/StarChat`，基线exact c628fe2e6706000cd721d6118c3e8ef8d372d7e2；U:临时映射到该树，结束恢复history-icons-performance-2204。所有权为SDK client/database_api/matrix_sdk_database/timeline_id_store及其stub、retained_search_store及其stub、新测试sdk_upgrade_sync_progress_test；不改登录鉴权、密钥或服务器。

已证明的源码阻塞：真实oneShotSync在收到响应后，预迁移所有响应房间三个片段。无timeline消息的房间，以及limited响应内即将被原子替换的旧main，也进入全量旧ID迁移等待。合成held-reader RED两次600ms超时；候选按实际timeline写入选择预准备，limited main由原事务reset后写入，pending/recovery独立保留。不能凭此认定账号手机唯一根因或OOM；生产诊断没有未结算await细分栈。

另两条RED：缺payload旧ID在跳过迁移后被search遗漏，及正在迁移的旧snapshot在limited替换后仍拖住新读。已补延后、每页<=256的只读legacy search种子与已提交ready新epoch快速确认。SPEC发现clear代际race，再用门排队RED证明旧placeholder跨clear存活，修复为取得事务门后重新检查代际。7新用例覆盖多房间/待发送与recovery/缺payload搜索/迁移交叠/原子失败回滚/SQLCipher半迁移重开512IDs/clear排队，实际exit0。SPEC最终PASS，QUALITY待结果。

证据位于managed树`docs/verification/artifacts/2026-10-08/android2205-empty-room-investigation/`：sdk-upgrade-red.log（exit1，2超时）、preservation-overlap-red.log（exit1，漏ID与超时）、clear-race-red.log（exit1，clear后残留）、upgrade-seven-green.log（exit0，7PASS）。原迁移25万ID真实SQLCipher/worker基线7334ms、每页<=256，不支持仅凭两个连接宣称死锁。focused首次43PASS；扩展run58PASS/1FAIL为新夹具先初始化普通ffi后不能改载cipher库，已改为所有新用例使用生产ffiInit工厂并7PASS，不隐藏该失败。全量/analyze/原生Android待门禁。锁文件离线enforce-lockfile成功，ffi/sqlite3版本没变。

当前设备：adb devices为空，无连接Android设备；WindowsSQLCipher/isolate证据不替代Android真机。发布候选前还必须验证2206旧格式写入后滚回新索引的权威桥接（ready索引可能旧）、平台原生门禁与真机缓存/同步。当前pubspec仍2205，绝不发布为已修复包。`.env`缺失，禁止借生产秘密满足verify.ps1；执行适用源码/边界门禁并记录缺口。

下一可执行步骤：最终源码formatter/analyze/Flutter全量与mobile边界门禁；QUALITY审查；记录准确输入SHA和失败分类；独立推进Android平台及2206回升桥接，未验收前保留稳定2206渠道。
## 2026-10-09 00:10+08 候选验证闭合（用户手机故障未闭合）

[有界源码修复报告](../../verification/2026-10-09-android2205-sync-progress-source-fix.md)。8新增用例PASS（新增真实恢复cached账号/OLM与首轮sync）。最终analyze0问题，移动boundary364PASS/23skip。全量5638PASS9skip1FAIL仅测试TEMP旧断言；按AGENTS修复测试目录断言，保持pid隔离/source exclusion，单文件79PASS。产品源未改，按规则复用其余全量证据；没有将旧全量失败记为exit0。SPEC后QUALITY最终PASS，fixture补审PASS。

Android source ARM64 release/AOT编译重试exit0/65.9s，产物仍0.4.36+2205原版本，仅验证中间物，未做发行重建/签名/上传。首轮126.4s失败根因 GeneratedPluginRegistrant误引用测试integration_test插件；原--no-pub沿用测试生成文件，按runbook正常pub/生成流程修复。锁文件未变，既有KGP/旧API警告留档，不是产品修复范围。初版真实账号夹具未种Olm pickle，错误地走新设备key-upload并失败；现以合成保留Olm pickle验证真正覆盖升级，不修改实际加密/鉴权。

ROOT状态：已证明源码三处等待/竞态，不宣称是手机唯一根因或OOM。FIX状态：有界源码候选已验证，生产2206未改；2206旧SDK写入后ready索引freshness回升兼容、Android运行/实际手机故障验收仍待完成。没有可用adb/AVD。下次恢复先读此候选工作树，不回到有其他iOS改动的history树重做；下一条执行步骤：写2205→2206旧格式新消息→候选回升RED，证明ready ordering/search新鲜度再保数据修复；随后平台运行验证/包交付门禁。不得直接发布当前仍2205版本的源APK。
## 2026-10-09 00:43+08 回退后再升级兼容修复

所有权追加：SDK matrix_sdk_database/timeline_id_store/retained_search_store与新legacy_rollback_rollforward_test。真实SQLCipher夹具复现2205 ready索引→2206旧格式新增/修改/移除消息→候选再升级：旧timeline漏新ID，旧search保留已移除记录；rollforward-red.log退出1。兼容修复仅添加本地元数据列和索引，在Box缓存开启前原子消费2206回退完成标记，旧epoch失效；记录按需分批准备，搜索按捕获revision退休旧索引，保留随后新增项与删除标记。不改消息正文、旧JSON、账号和密钥。4条升级用例包含ready、copying、事务中断与重试，真实SQLCipher全部PASS。

00:34专项重跑65PASS/exit0，覆盖原同步/索引与新增回升。前一轮64PASS/1FAIL是测试ObservedSql适配器无直接execute；将新表列包含于CREATE、旧表ALTER使用已有batch接口后通过，未删除/弱化分页测试。全量最终00:42完成5644PASS/9skip/exit0（6m24s），移动边界364PASS/23skip/exit0（62.34s），analyze无问题/exit0（13.5s）。证据：rollforward-focused-retry.log、flutter-full-rollforward.log、mobile-boundary-rollforward.log、analyze-rollforward.log。规格审查随后质量审查PASS，最终marker-absent/批DDL补审PASS。

回升兼容源码门禁已闭合；Android最终源编译进行中。仍没有连接设备或AVD，不能以Windows SQLCipher测试/ARM64编译替代实际Android运行和用户数据覆盖升级。稳定2206生产分发未改；不发布当前2205源中间包。

2026-10-09 00:45+08：最终兼容候选 Android ARM64 release/AOT编译exit0，Gradle71.8s。源包仍2205，仅中间物未分发。下一步准备独立递增版本的固定签名候选，保留稳定2206渠道；实际手机覆盖升级/首次sync/空列表和入房验收仍未执行。

2026-10-09：已生成0.4.38+2207固定签名重建候选，[候选任务](2026-10-09-android2207-fix-candidate.md)。28包门禁通过，1904移动输入冻结，生产2206未变。待保留原数据的Android覆盖升级验收；未发布/触发弹窗。
