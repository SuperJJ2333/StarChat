# IM 可靠性与性能分阶段修复方案

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 先修复现场已确认的恢复鉴权错配和可隔离复现的通知/媒体缺陷，再逐批改善双端后台、收发、内存和启动，并补齐最终设备验收。

**Architecture:** 保留Matrix通信域、业务API权威、现有客户端缓存/事务队列及推送入口。采用独立有界补丁，按当前运行镜像作精确增量；首批不迁区、不更换消息协议、不重写客户端、不调整金融权威。

**Tech Stack:** Flutter/Dart、Android Kotlin及受控插件补丁、iOS Swift、Matrix SDK/Synapse、FastAPI/SQLAlchemy/PostgreSQL、Getui/Sygnal、Nginx/Docker Compose。

**Spec:** [现行产品规格](../specs/2026-08-12-starchat-product-modernization-design.md)、[九项评审](../../verification/2026-10-11-e2e-architecture-performance-review.md)、[本轮服务器事实](../../verification/2026-10-11-server-runtime-followup.md)。历史发行/命名冲突按当前用户指令及根AGENTS覆盖。

**状态与授权：** 2026-10-11 用户进一步明确“继续修复”，并授权自行决定产品修改、服务重启和部署；按本计划分阶段实施。执行证据与每项状态见[独立任务记录](../../workflow/tasks/2026-10-11-im-reliability-implementation.md)。未勾选门禁不代表已完成；设备、签名和厂商审核各自阻断依赖步骤。

## Global Constraints

- Android小米/OPPO/vivo等厂商通道处于上架审核，标记`EXTERNAL_PENDING`；不计作今日配置bug，不虚报已验收，也不以其阻断独立修复。iOS APNs已配置production，独立处理。
- 不绕过系统通知权限、Focus/DND，不自动拉Activity，不用无限持锁、精确Alarm或服务重启循环规避系统限制。
- Matrix/业务域边界、金融Decimal/幂等/审计/Outbox、E2EE/恢复权限、账号代际、同txid和撤权复查保持。服务器不获取新增消息明文、用户恢复密钥或附件明文。
- 根AGENTS对密钥与信任边界的约束优先；本方案不延伸或自动沿用历史文档中的托管授权。SR1仅修复已有鉴权寻址，任何恢复策略/信任边界变化先另立ADR及领域、质量安全审查。
- 不清空手机数据、不批量重放历史金融死信、不停未知归属演练容器、不清理现存生产日志以制造“健康”。
- 每项先RED→GREEN，再规格/领域→质量安全；独立任务不能同时编辑同一文件。合入和发版绑定实际SHA，复用输入未变的已完成门禁。
- 所有操作用PowerShell7/UTF-8；本地临时证据仅放docs/verification下。方案中的时间/成功率为待冻结目标，不是当前保证。

## Review Focus

- 修正恢复端口后，合法status仍依赖完整鉴权和隔离测试keyring；TCP成功不是恢复成功。由R1集成用例覆盖。
- 推送部分成功后503重试不能重复提醒，也不能把未尝试房间当成功。由R2混合结果/并发用例覆盖。
- 原生FGS超时时Dart可能不运行；锁必须由native释放，且不能误停通话owner。由R4原生故障用例覆盖。
- iOS定时DND跨午夜时应用可能挂起；仅在前台更新pusher无法保证时段策略。由R5独立服务端策略设计/验收覆盖。
- 媒体任务持久化必须区分可丢弃缓存和唯一待发原件；取消/切账号/低空间不能删除或跨账号重放。由R8故障矩阵覆盖。

## 执行顺序与职责

| 批次 | 任务 | 可并行与依赖 | 成果 |
| --- | --- | --- | --- |
| 发布事实先行 | R0最终iOS身份 | 与服务器代码修复并行；需要实际最终包/设备 | 明确有效签名身份、旧用户连续性与APNs匹配，保留N2-1 P0门禁 |
| 第一批 | R1恢复端口、R2通知节流、R3媒体IO、R4 FGS | 四个源码域可各自隔离；R1受保护域独立双审 | 四个可单独回退的最小补丁 |
| 第二批 | R5绑定/声音、R6发送公平、R7交互/启动 | R5与R4涉及app接线时统一owner；R7内部按文件串行 | 双端状态真实、健康房间不被慢房间拖住、交互有预算 |
| 第三批 | R8媒体恢复/缓存、R9运营边界、R10观测/容量 | R8先预算和文件接口，再持久任务；R10支持所有批次 | 可恢复附件、存储边界、可验证SLO |
| 外部条件满足后 | R11逐OEM接入与灰度 | 每厂商资格/签名/控制台具备后独立开始 | 真实锁屏/回收场景结果，不靠服务端200代替 |

不估算无团队产能依据的工期。推荐先完成R1–R4的小补丁与R0事实闭环；不把26项一次性改造捆绑发布。

## R0 / P0：最终iOS成品身份与APNs交付闭环

**Files:** 复用`scripts/verify_ios_enterprise_ipa.py`、`tests/mobile/test_verify_ios_enterprise_ipa.py`及现有发布流程；本项不先改生产APNs配置。归档身份结果到新的版本专属verification目录。

**Interfaces:** 输入为实际安装/准备交付的最终IPA SHA、Bundle/AppID/Team/aps-environment、旧安装身份和现配置比较布尔；输出为该精确成品的身份、覆盖升级和通知验收结论。

- [ ] 先核对用户实际安装包是否仍为10/9的2213 SHA，复用相同输入既有验包证据；变化时重新验证实际新成品。
- [ ] 列出AppID/Bundle及APNs topic/Team差异，确认目标发行身份；不通过换APNs密钥迎合未闭环回签包。
- [ ] 在保有旧数据的测试iPhone不卸载覆盖，验证Keychain/聊天、冷启动、普通APNs及CallKit。测试请求需绑定明确测试账号与设备。
- [ ] 验收身份差异得到解决或有具体受验解释、旧数据连续；所有结果绑定最终SHA。没有设备结果仍标未验，不写“推送已全恢复”。

## R1 / P1：恢复鉴权上游端口最小修复（新增SR1）

**Modify:** `third_party/synapse/chatflow_recovery_vault.py:22`、`tests/infra/test_synapse_recovery_vault.py`、`tests/infra/test_synapse_recovery_postgres.py`、`docs/runbooks/server-recovery-vault.md`。

**Create:** `tests/infra/test_recovery_authority_topology.py`（新文件）。输入参照现有`docker-compose.yml`的business-api监听/healthcheck和`infra/nginx/nginx.conf.template`的8082上游。

**Interfaces:** 保持`Authority.verify(request, expected=None)`和wire contract不变；唯一连接目标固定为`http://business-api:8082/api/v1/auth/matrix-recovery-authorize`，不引入任意URL配置入口。

- [ ] 写`test_authority_port_matches_business_service`，断言固定内部主机/路径、8082与Compose健康检查一致；在当前8000源码先得到预期RED。
- [ ] 写隔离同拓扑集成：business-api只监听8082，使用纯测试身份/测试keyring，合法status成功；错误双凭据、撤销、过期、依赖拒绝/超时均保持拒绝，不写状态。复用并扩展现有原生PostgreSQL/撤权夹具，不读取生产keyring。
- [ ] 只改固定端口并更新部署回归说明；保留5秒依赖超时、最终撤权复查、fail-closed及日志脱敏。
- [ ] 运行`python -m pytest -q tests/infra/test_recovery_authority_topology.py tests/infra/test_synapse_recovery_vault.py`；真实PG/native门禁使用现有隔离编排。PASS要求所有新增/相邻用例通过；未具备原生环境不冒充通过。
- [ ] 领域/规格→质量安全评审后冻结最小镜像与回退镜像。若后续获部署范围，main/worker需按现有共享模块兼容流程发布，仅回退镜像/连接目标，不回滚或删除恢复表/密钥。验证普通收发、模块导入、双重鉴权及指定测试身份status，不能只凭TCP连通结案。

## R2 / P1：区分通知去重与跨房节流

**Modify:** `services/getui-bridge/app/rate_limit.py`、`main.py`，必要时`notify.py`；测试`tests/getui_bridge/test_native_message_contract.py`、`test_error_semantics.py`、`test_bridge.py`。

**Interfaces:** 消费现有`NativeEnvelope(scope, room_key, event_key)`的会话域摘要，供应商payload不加入正文/原始房间ID。永久CID拒绝才进入rejected；临时失败保持503协议重试。

- [ ] 将已保存的“A/B两房100ms仅一次provider调用”复现转为正式RED；新增A静音/B非静音、相同event重复、同房突发、多CID部分成功/503、旧失败释放新reservation等用例。
- [ ] 第一补丁让v1普通消息按scope+room区分通知机会；同event去重独立于容量限制。若需要尾沿合并，合并结果需可观测、等待有界，未投递/未可靠接管的事件不得HTTP200静默丢弃；legacy无scope路径保留明确兼容语义。
- [ ] 限制状态表、TTL和总并发，满载返回可重试结果；不要直接把1500ms改0，也不恢复绕过本地静音的UPS直显。
- [ ] 执行`python -m pytest -q -p no:cacheprovider tests/getui_bridge`（预检PYTHONPATH对应该服务）；原38项及新增全部通过，按失败业务码/连接超时/读取超时验证重试。
- [ ] 仅改桥接镜像即可回退；真机已有个推通道另验收，供应商HTTP200和设备显示分开。厂商未开通不阻塞该源码修复。

## R3 / P1：卸载业务媒体同步IO，先控制事件循环阻塞

**Modify:** `services/business-api/app/api/media_platform.py`及现有头像读取路由的同步调用边界；必要时`app/integrations/media_blob_storage.py`。现有安全回归：`tests/business_api/media_platform/test_media_gateway.py`、`test_media_authorization.py`及`tests/business_api/media_storage/test_s3_failure_recovery.py`。

**Create:** `tests/business_api/media_platform/test_media_event_loop.py`（新文件）。详细运行身份与子方案见[后端要点](../../verification/artifacts/2026-10-11/server-followup/backend-plan-notes.md)。

**Interfaces:** 保持现有signed/private/audience URL、鉴权、撤权、校验和错误契约；不要将SQLAlchemy Session从创建线程任意跨线程复用。把完整同步业务操作放入有界worker执行上下文，在该上下文创建/结束其资源。

- [ ] 将已有真实路由250ms阻塞探针转成异步回归RED：同时发慢媒体请求和无关轻量请求，确保测试确实共享一个事件循环。
- [ ] 无await的同步只读路由可改为框架同步路由；混合异步读取请求体的路由使用有界worker包装同步业务段。选择现有框架/依赖提供的线程机制，不首批更换S3 SDK。
- [ ] 覆盖2worker并发、线程/Session归属、存储超时、权限撤销、损坏、取消和低空间；先解决阻塞，再另立全对象内存/流式优化，不能提前输出未校验内容。
- [ ] 运行上述专项及适用media_storage回归；隔离250ms存储等待期间10ms timer与无关请求可正常推进，校准负载下event-loop lag P99<50ms，线程/在途工作有上限。
- [ ] 交付仅业务API最小镜像，遵守既有refresh release guards；回退到冻结兼容镜像，无数据库降级。上线前后同时看媒体与非媒体API，不只看ready200。

## R4 / P1：Android FGS实际状态、超时与锁释放

**Modify:** `apps/mobile_flutter/lib/core/notification/sync_keepalive_service.dart`、`foreground_service_arbiter.dart`、`android/app/src/main/kotlin/com/liuhetong/mobile/MainActivity.kt`、`android/app/src/main/AndroidManifest.xml`、`pubspec.yaml/pubspec.lock`；对应现存`test/core/notification/sync_keepalive_service_test.dart`及`foreground_service_arbiter_test.dart`。

**Create:** 仓库内固定19.4.2的`apps/mobile_flutter/third_party/flutter_local_notifications/`受控fork，保留许可证；原生`SyncKeepAliveResourceOwner.kt`及同包测试。不能修改全局Pub缓存。本批选择最小fork路线，不同时引入第二套常驻服务。

**Interfaces:** native owner管理CPU/WiFi锁；Dart区分desired与实际running，acquire反馈真实成功/失败，timeout/destroy先native释放并stopSelf，再尽力通知Dart。

- [ ] RED覆盖native false/异常、start被拒、start迟到遇stop、Dart挂起时timeout、重复stop、通话owner并存。现有“start失败继续持锁”旧断言替换为有依据的新契约，不只删测试。
- [ ] 增加onTimeout/onDestroy生命周期处置，停止无意义watchdog重申；下次合法前台恢复再重新请求，不提高后台拉起频率。
- [ ] Flutter专项+Android原生编译/单测；测试设备短FGS配额演练后恢复device_config，再做真实长时限锁屏。native锁归零、无超时致命异常，状态不虚报running。
- [ ] 新APK固定签名、常规重建与保数据安装；功耗和Doze到达单列，不能以无厂商通道时的服务存活承诺所有ROM到达。

## R5 / P1：远端pusher对账，随后修复iOS声音策略

**Modify:** `apps/mobile_flutter/lib/features/push/matrix_pusher_service.dart`、`push_status_registry.dart`、`lib/app_home.dart`、`lib/core/notification/notification_coordinator.dart`；现存`test/features/push/matrix_pusher_service_test.dart`、`push_status_registry_test.dart`、`test/core/notification/ios_silent_presenter_test.dart`。

**Interfaces:** `MatrixPusherGateway`增加远端list/read能力，SDK实现调用既有getPushers；注册身份包含声音策略，区分last write与last remote verification。本主计划采用**5分钟**最大对账陈旧预算，覆盖客户端子建议15分钟；注入时钟、前台/网络恢复合并触发。

- [ ] RED：本地注册成功→远端删除→token不变，对账必须重建一次；20次并发resume不产生20次写；429/离线为未知，旧账号迟到结果不能覆盖新账号绑定。
- [ ] 保留generation/binding owner和幂等upsert；网络失败指数退避，不用每次build读远端。下一次可联网前台恢复或5分钟预算内完成验证/补齐。
- [ ] 第二门禁加入iOS静态声音开关：关闭时最终APNs payload无sound，开启恢复default；用真实Sygnal构造fixture验证省略字段不会被默认配置补回。偏好持久化后触发同一owner收敛，失败明确远端待同步，前台副本抑制保持。
- [ ] 定时DND跨午夜单独设计在推送发出前执行的时区/窗口策略，只传必要非敏感元数据；不能依赖挂起App定时改pusher或NSE必执行。设计/网关fixture与真机通过前，该子项仍未完成。
- [ ] 真机按系统声音允许/Focus/静音、前台/后台/锁屏核验；同event最多一次，关闭无意外声，角标/点击只进入当前授权账号。不改VoIP通话策略。

## R6 / P1：文本发送跨房间公平调度

**Modify:** `apps/mobile_flutter/lib/core/outbox/message_send_scheduler.dart`；现存`test/core/outbox/message_send_scheduler_test.dart`、`unbound_resolution_retry_test.dart`。

- [ ] RED：A房3条sender一直pending，B房即时完成，以及unbound解析一直pending；B需在注入测试时钟200ms内进入transport。
- [ ] 每房保序且最多一个真实in-flight，跨房并发初始上限2，轮转派发；unbound解析有独立预算，不挡已绑定房间。
- [ ] 覆盖超时、迟到ACK、429、撤权、重连及取消，保持原txid/claim和本地插入时间；UI观察超时不代表真实传输已结束。
- [ ] 专项全文件通过；隔离SDK联测无重复气泡/倒序或跨账号重放。仅回退调度策略，不丢弃已持久化任务。

## R7 / P1：分开领取交互、提及和启动任务

此批不是一次大重构，以下每行独立RED→GREEN/评审；共享matrix_e2ee_client的修改按一个owner顺序集成。详见[客户端准确文件及测试清单](../../verification/artifacts/2026-10-11/server-followup/client-plan-notes.md)A4/A5/A6/B3。

| 子任务 | 主要文件 | 先写失败用例及最小方向 | 验收 |
| --- | --- | --- | --- |
| R7a提及正文有界 | room_mention_store.dart、unread_mention_tracker.dart；新mention_history_scan.dart/test | 10万未读累计Event超过预算；固定scan head/read marker、next(limit=256)分页，只ingest新增页，500ms交互安静后维护 | 正文常驻≤256，读取O(N)，取消≤200ms；已查看/撤回不复活，元数据增长另做迁移 |
| R7b重复同步hash | media_cache.dart、content_addressed_media.dart；新verified_media_content.dart/test | 计数hasher证明同一受控链重复全量digest；worker校验后通过不可伪造内部类型复用，外部不可信输入仍验证 | UI无长同步hash，完整性/跨账号/取消回归通过；不改变加密参数 |
| R7c启动安全壳 | installation_startup_gate.dart、main.dart及既有gate测试 | reconcile/start永不完成；1秒预算后允许无账号内容的安全首帧，3秒仍等待展示真实阶段 | 不无限白屏、不清库、不并行重复open，迟到完成只发布一次；短启动保持原体验 |
| R7d旧历史/提及元数据 | SDK timeline_id_store.dart、timeline_migration_reader.dart及现有迁移测试 | 先重现百万未知/尾部ID冷查询；后台完整索引或批量预查；tracker改游标/区间需版本迁移 | 无索引不等于不存在，保留正文/epoch/回退升级；记录同机同夹具前后耗时 |

- [ ] 每子任务读取相应现存测试后添加精确RED并执行。
- [ ] 最小修改通过原用例及新增用例；性能用工作量/执行上下文确定性断言，毫秒预算由真机profile验收。
- [ ] 统一共享候选做弱网+快滑+键盘+切房组合，记录frame denominator及Android退出/iOS Jetsam，不凭模拟器debug宣称低端真机流畅。

## R8 / P1-P2：媒体峰值、持久任务与目录策略

详见客户端子方案A7/B1/B2；按以下依赖顺序分别领取，不将流式协议变化混入R3。

- [ ] **P2提前大小预检（V6-3）：** 修改media_message_service.dart及相关SDK能力适配；创建服务器50MiB/文件64MiB普通文件夹具，先RED，再在read/cache/encrypt前拒绝；边界取客户端、服务器和已知代理约束最小值，视频按转码后大小判断，保留SDK最终守卫。不直接提高生产上传上限。
- [ ] **P1活动媒体预算（R5-2）：** 新media_transfer_budget.dart/test，先测10/50/100MiB混合场景，再按source/密文/下载/解码预留总字节；取消/失败归还。后续文件流式化保持ADR-0060字节/加密/完整性兼容，不能提前播放未校验明文。
- [ ] **P1目录/备份（S8-1/2）：** media_cache.dart增量配额索引，后台校准替代每次全目录扫描；原生固定chat-media目录设置并读回isExcludedFromBackup，先用合成目录验证缺口。可再生缓存和唯一待发原件分域，待发文件不能被缓存GC/备份规则意外丢掉。
- [ ] **P1附件恢复（V6-1）：** 新core/outbox/media_outbox_store.dart、media_outbox_recovery_service.dart及测试；persist-before-admission，保存账号代际/txid/目标/文件身份/阶段，不保存token/room key；恢复先权限核验，上传成功而ACK未知仍复用txid。
- [ ] 在每个持久化、上传、发event、ACK边界注入进程死亡；每类100次合成故障恢复或明确可操作失败，0静默消失/重复事件/跨账号重放。低空间、源丢失和卸载外的覆盖升级单列。

## R9 / P1-P2：运维边界与历史数据治理

**Modify:** 当前实际Compose层、`docker-compose.yml`和`infra/nginx/nginx.conf.template`的受影响服务配置；新`tests/infra/test_core_log_rotation.py`。现有原始镜像/配置快照作为回退依据；不要拿本地模板直接覆盖全部生产配置。

- [ ] **SR2/P2轮转：** RED断言目标核心服务logging明确`json-file`及有限max-size/max-file；初始20m×10，按增长率/留存校准。在隔离容器验证轮转，真实生效以新容器inspect为准；旧日志保留归档，不truncate。
- [ ] **A7-1/P1资源：** 连续7–14天峰值CPU/PSS/PSI/swap IO/磁盘/连接，明确演练owner；先隔离环境验证预留与限制，不能按当前瞬时RSS直接设置过低上限。
- [ ] **A7-2/P1冗余：** 在同构环境加入第二sync worker和健康感知切流，验证单worker失效、重连与追赶；整站恢复另冻结RPO/RTO。Main未证明足够备用容量前不盲目failover；不引入金融跨区双写。
- [ ] **A7-4/P2 Outbox：** 当前新事件正常，先写慢topic/整批超过5分钟租约的隔离用例，再决定按topic公平与续租；保持原幂等。103235历史DEAD及已handover的2旧PENDING按既有财务任务归属处理，不批量删除/重放。
- [ ] **S8-3/P2归档：** 工作树/证据保留期和owner确认、按摘要证明重复、恢复抽检后才形成清理清单；本轮逻辑长度不是可删除字节量。**A7-5/P2模块化**在上述行为测试稳定后按边界逐步拆分，不先重写9764行客户端。

## R10 / P1：观测、设备和容量准入

**Modify:** 现有performance trace/diagnostics、业务tracing、Getui标准结果统计；新增测试只覆盖真正新增的脱敏/分桶行为。详细文件分配在领取各R1–R9任务时绑定，不开一个可无限扩张的“全站监控重写”。

- [ ] 固定tap→本地持久化→加密→ACK→收端sync→解密→落库→首帧阶段；推送区分供应商HTTP、业务受理、设备收到、系统展示、声音、点击。只用短期opaque标识与固定错误枚举，不记录正文/token/CID或签名URL。
- [ ] 对已有探针401、空闲30秒sync、HTTP完成/未完成、tail截断/丢样分别分桶；原日志未匹配行不能消失。为R1恢复503和R3 event-loop lag增加不含敏感内容的指标。
- [ ] 参照九项报告设备矩阵：Android重点12–17/低内存及主要ROM，支持下限/存储边界另抽测；iOS16旧问题机到新版本，保数据升级与最终签名绑定；弱网、离线10分钟、8小时锁屏、系统回收、force-stop分别验收。
- [ ] 真实独立SDK的200→500→1000成员E2EE群与混合负载，在隔离同规格环境三轮验收，负载发生器独立；保留密钥轮换，不用HTTP200代替每接收端解密对账。
- [ ] 首轮建议：正常文本P95≤1s/P99≤3s，指定弱网P95≤5s/P99≤15s；离线1000条恢复60秒完整对账；发送反馈P95≤100ms；后端loop lag P99<50ms。样本量、置信区间和所有超时必须报告，数值不作为未测场景保证。
- [ ] 灰度出现数据丢失/重复、跨账号、鉴权放宽、持续崩溃立即停止对应候选；性能超过预算按设备桶止扩，不通过关闭日志或排除失败分母制造达标。

## R11 / 外部待办：厂商审核通过后的接入

- [ ] 按实际获批厂商逐一核对SDK、包名、固定签名、应用ID、控制台映射、生产环境和回执；secret只留受控服务端配置。
- [ ] 设计与现v1账号scope、静音/DND/已读策略兼容的离线呈现；服务端直显不能绕过用户偏好，不向供应商传聊天明文。
- [ ] 逐ROM覆盖前台、Home、清最近任务、LMK、锁屏30min/8h、重启、Doze/省电/白名单；用户force-stop按系统受限预期独立汇报。
- [ ] 每个设备/版本/SHA/渠道/状态桶给出分母、到达及延迟；系统允许且通道有效桶建议30秒可见≥99%、P95≤5s/P99≤30s，人工/声学声音检查另列。未获批桶继续标外部待办，不伪造0%或100%。

## 原评审覆盖映射

| 评审项 | 对应任务 |
| --- | --- |
| B1-1/2/3 | R4、R11、R5 |
| N2-1/2/3 | R0、R5、R2 |
| M3-1/2/3 | R6、R10、R10 |
| U4-1/2 | R7d、R7b |
| R5-1/2 | R7a及R7d、R8 |
| V6-1/2/3 | R8、R3、R8 |
| A7-1/2/3/4/5 | R9、R9、R10、R9、R9 |
| S8-1/2/3 | R8、R8、R9 |
| L9-1/2 | R7c、R0及R10 |
| 新增SR1/SR2 | R1、R9 |

## 实施与交付门禁

每个独立任务先确认HEAD、依赖锁、实际导入路径和所需环境；先专项RED，再最小修改GREEN及相邻回归。执行代码变更后按mobile-delivery-workflow做适用verify预检和门禁；Windows缺.env、原生设备或真实PG时记录阻断的具体子项，不能导入生产秘密跑测试，也不能用文档核验代替产品测试。

后续获准实施时按文件所有权建立隔离worktree；小补丁独立提交并经规格/领域后质量审查。共享候选冻结后统一一次适用全量/analyze/平台编译，未变输入不重复构建。Android仍需固定签名常规重建；iOS仍需最终签名/身份/保数据验收。发布与回退精确绑定当时运行镜像和Compose层，遵守续期协议门禁，不覆盖无关服务。

本方案的修复路径、可测试任务和验收标准现已进入授权实施；以任务记录区分源码、测试、候选、部署及设备验收，保留未完成项。

## 2026-10-12 R8媒体发送P0回归追加

Android2214用户报告图片/视频全机型红叹号；本轮实际main debug在API28 x64复现JPEG红叹号和MP4发送失败，媒体outbox未激活。最小启动顺序修复已RED→GREEN/独审；2215 debug保数据覆盖、图片原图/视频播放及服务端同步通过。正式ARM642215已固定签名常规重建，最终共享5965/9、Python401/1、analyze及28打包门禁通过，发布尚待精确package双审与生产后验。详见[独立任务记录](../../workflow/tasks/2026-10-12-android2214-media-send-regression.md)，不能将单模拟器验证扩展为全ROM/真机/弱网/16KiB结论。

### 2214媒体P0回归最终结果

2215最小启动顺序修复完成，真实模拟器图片/视频发送ACK及重开通过；5965/401适用门禁及成品双审通过。2026-10-12 22:25+08正式发布、22:28审计、22:31公网检查通过。两文件下载源码回填完成；不把全ROM真机、16KiB、OEM审核缺口标为已解决。
