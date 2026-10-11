# 服务器核查后客户端修复计划要点（供主计划合并）

状态：2026-10-11只读设计建议，**没有实施授权推定、没有修改产品源码、没有构建或测试运行**。用户目前要求服务器现场核查后给方案。主计划由主agent统一写入批准计划目录；此文件只归客户端计划子任务。计划组织采用writing-plans，测试文件均现场核对；不存在的文件明确标为Create。

基线：main `5c83a08a09b985146bc507a1608cb2153d361e48`，此前客户端评审见 `docs/verification/artifacts/2026-10-11/e2e-architecture-review/client-review.md`。外部平台政策/现场服务端证据由主agent负责核对，本文件不把旧报告当当前生产状态。

## 适用规格与限制

已读：

- `docs/superpowers/specs/2026-08-12-starchat-product-modernization-design.md`：Matrix是密文通信域，普通消息/附件/恢复密钥不交业务API或推送，日志不得带正文/token/key；客户端弱网消息重试和附件恢复需验收。冲突历史命名/发行条款按current-state及当前用户指令覆盖。
- `docs/superpowers/specs/2026-10-03-mobile-ui-push-2196-design.md`：普通推送不自动拉Activity，不使用full-screen intent；静音/去重/账号撤销保持；模拟器不能证明Redmi/iPhone锁屏耐久。
- `docs/superpowers/specs/2026-09-30-mobile-perf-mute-media.md`：静音群默认无声/无振动/无弹窗；后台媒体尊重OS；iOS强制退出后不能承诺Dart持续执行；缓存清理不能注销推送。
- `docs/superpowers/specs/2026-10-08-history-interaction-fix.md`：HTTP ACK不充当权威timeline确认，保持同txid、本地插入时间、历史/分页/已读/撤回。
- `docs/superpowers/specs/2026-10-09-mobile-responsive-maintenance-design.md`：交互结束空闲至少500ms后维护、最多1个重维护、每批≤256ID、批次事务目标≤4ms、worker额外缓冲目标≤8MiB、首屏40/视窗200；真机60Hz p95<16.7ms是待测目标，不是已证明值。
- `docs/superpowers/specs/2026-09-27-ios-startup-diagnostics-design.md`：诊断只含固定枚举/公开版本等允许元数据，不绕过身份/Keychain/本地恢复，诊断不参与启动成功判断。

**OEM审核边界（必须进入主计划）：** 小米/OPPO/vivo等Android厂商通道当前因上架审核不能配置；标记 `EXTERNAL_PENDING / NOT_APPLICABLE_TODAY`，不计今天代码通过率分母、不是配置BUG、不是阻塞所有修复的前置条件。保留现有已可用Getui/FCM路径和系统允许的前台同步；不通过无限wakelock、精确Alarm、重启服务循环或自动拉Activity替代厂商通道。iOS APNs单独检查证书/环境/授权/token/pusher/payload和真机结果，不能归入Android OEM审核缺口。

所有下面的RED均指**实施时新增并先运行**的失败用例；本轮没有实际执行，不伪称已RED或已GREEN。数值建议若非引用规格，需要主计划明确采纳后再作为验收标准。

## 第一批：可独立评审、尽量小范围的修复任务

### A1. Android FGS/锁状态真实化，系统超时后可靠释放

**现行事实：** `lib/core/notification/sync_keepalive_service.dart:48-53`忽略native bool结果，`:312附近`即使acquire失败仍把_locksAcquired设true；start失败仍进入取锁。`foreground_service_arbiter.dart:203-216`吞backend异常，上游不能判断应用是否成功。`android/app/src/main/kotlin/com/liuhetong/mobile/MainActivity.kt:425-447`PARTIAL锁20min、WiFi锁无timeout，由Dart10min看门狗重申。锁文件`pubspec.lock:517`插件19.4.2；已读本地Pub缓存对应`ForegroundService.java`，只有onStartCommand/onBind，无onTimeout override。不能把源码注释“Android14+约6h”当平台规范，主agent需按真实target/API核对。

**Modify（均已存在）：**

- `apps/mobile_flutter/lib/core/notification/sync_keepalive_service.dart`
- `apps/mobile_flutter/lib/core/notification/foreground_service_arbiter.dart`
- `apps/mobile_flutter/android/app/src/main/kotlin/com/liuhetong/mobile/MainActivity.kt`
- `apps/mobile_flutter/android/app/src/main/AndroidManifest.xml`
- `apps/mobile_flutter/test/core/notification/sync_keepalive_service_test.dart`
- `apps/mobile_flutter/test/core/notification/foreground_service_arbiter_test.dart`

**Create（计划新增，不是现存）：** app原生资源owner `apps/mobile_flutter/android/app/src/main/kotlin/com/liuhetong/mobile/SyncKeepAliveResourceOwner.kt` 及其 `apps/mobile_flutter/android/app/src/test/kotlin/com/liuhetong/mobile/SyncKeepAliveResourceOwnerTest.kt`。把Activity内锁持有移到application-scope owner，使服务销毁/超时即便无Dart也能释放。

**最小路径/接口：** hooks.acquire改为返回真实是否获取；backend/arbiter返回applied/denied/stopped状态，而非用“不抛异常”代表running；desired ownership与OS实际running分开。FGS被系统超时/销毁时native owner释放CPU/WiFi锁，通知Dart置stopped并停止定时重申；只有后续合法前台生命周期/显式重连允许重新申请。插件没有生命周期通知，正式实施需在仓库内固定19.4.2的受控local fork加onTimeout/onDestroy通知（Create `apps/mobile_flutter/third_party/flutter_local_notifications/`，修改现存pubspec.yaml/pubspec.lock并保留license），**不能编辑全局Pub缓存**。native timeout通知必须先在native释放资源/stopSelf，再尽力通知Dart；不能依赖Dart有机会回调才stop。若主计划选新的app-owned FGS替代fork，应先定接口再实施，不能两种路线同时并存。

**RED→GREEN：** 补false返回/异常返回不变true；native start拒绝不持锁；native timeout/Dart悬挂时锁归零且不自动重启；start迟到遇stop不复活；重复超时/stop幂等。现有C05“start失败仍弱保活持锁”的测试明确是要被新策略替换的旧契约，不能只删除测试；新增新的期望和依据。通话期间超时需独立fixture：系统要求停止的那个服务必须停止，原生有效通话服务及UI不能误停/虚报重新运行。

**验收/边界：** 模拟超时后native锁0、watchdog无重启、running准确；Android平台原生测试+实际目标API超时演练；被系统禁开FGS时聊天前台、显式重连仍可用。不得提高watchdog频率或增加绕限制权限；厂商未开通保持外部条件。

### A2. Pusher周期对账与iOS远程声音策略（同一owner，先绑定再声音）

**现行事实：** `matrix_pusher_service.dart:206-214`仅以本地token+metadata identity相等跳过remote写，服务端pusher被清除后same-token recheck仍true。SDK真实存在 `third_party/matrix/lib/matrix_api_lite/generated/api.dart:2729 getPushers()`。iOS payload `matrix_pusher_service.dart:225-234`硬编码sound=default；`app_home.dart:960-966`未注入声音偏好；`NativeMessagePolicy`默认只Android启用，不能据Android更新回调推断iOS远程payload同步。iOS `AppDelegate.swift:217-226`前台远程通知已抑制，不应拆掉防双响。

**Modify：**

- `apps/mobile_flutter/lib/features/push/matrix_pusher_service.dart`
- `apps/mobile_flutter/lib/app_home.dart`
- `apps/mobile_flutter/lib/core/notification/notification_coordinator.dart`
- `apps/mobile_flutter/test/features/push/matrix_pusher_service_test.dart`
- `apps/mobile_flutter/test/core/notification/notification_coordinator_test.dart`
- `apps/mobile_flutter/test/core/notification/ios_silent_presenter_test.dart`
- `apps/mobile_flutter/integration_test/ios_conversation_notification_native_test.dart`

**接口/方法：** 为MatrixPusherGateway新增读取当前绑定的read/list接口，Client实现调用SDK getPushers，测试gateway实现受控远端集合；为recheck提供forceRemote意图，并维护注入时钟的最后remote验证时间。建议最长15min staleness（主计划可调整），登录/恢复前台/网络恢复触发一次有节流对账；并发force请求coalesce，远端无本账号appId+token或payload不匹配才重建，网络失败保留待对账而不宣告已恢复。沿用现有binding owner/generation与补偿删除。

声音策略第二小门禁：添加iOS普通消息payload provider，content只有通用标题/文案和固定sound策略；policy参与registered identity。NotificationCoordinator在偏好成功持久化后通知composition root更新同一pusher；soundEnabled=false时远程APS不得有sound，true时恢复default。主agent先用真实Sygnal实现/fixture核对“省略sound”不会被网关默认payload补回，再定最终payload；不能只测Dart对象。失败时显示/记录“远程设置待同步”，不冒称关闭声音已经在远端生效。

**RED→GREEN：** same token成功后从fake远端删除，freshness到期/强制recheck后恰好重建一次；并发resume20次只一对账；getPushers失败、429、token换代、旧账号迟到create/logout不破坏新绑定；禁声false的APNs payload不得含sound，policy切换在途注册完成后收敛最新值；前台通知仍仅一次。

**验收/边界：** 经现场许可的测试设备上绑定丢失→恢复在一次受控对账内完成；远程通知在iOS后台/锁屏关闭声音无sound、开启后正常，系统设置/勿扰/Focus也记入结果。定时DND不能只靠App后台定时改pusher保障，要单列后续服务端策略/系统能力任务，当前不承诺定时DND已全覆盖。群静音仍由Matrix push rule负责；不改通话APNs/VoIP、密钥或推送明文边界。Android OEM待审核不参与此项失败统计。

### A3. 文本outbox跨房公平调度

**Modify：** `apps/mobile_flutter/lib/core/outbox/message_send_scheduler.dart`；测试 `apps/mobile_flutter/test/core/outbox/message_send_scheduler_test.dart`、`apps/mobile_flutter/test/core/outbox/unbound_resolution_retry_test.dart`（均现存）。

**最小方法：** 保持每房一个in-flight、有序认领；独立房间使用小并发lane（建议2）与轮转，每轮每房只拿一条可派发行；unbound receiver解析不挡已经绑定的房间。不要改Durable claim、txid、Retry-After、权限回查或SDK顺序。

**RED→GREEN：** A房3条sender永不完成，B房即时成功；当前串行会让B等待A预算，新实现要求B在测试时钟200ms内进入transport，A仍只一个真正in-flight；unbound resolver hang亦不挡B；A迟到ACK、取消、429与重连后仍0重复、顺序正确。运行现有整文件而非仅新断言。

**验收：** B独立请求的排队p95不随A的30s operationTimeout放大；并发≤2，同房确认序不倒置，原20s UI观察超时继续不释放真实claim；账号撤销停止所有新dispatch。

### A4. 提及正文扫描改固定页并接入维护预算

**Modify：** `apps/mobile_flutter/lib/features/matrix/room_mention_store.dart`、`apps/mobile_flutter/lib/features/matrix/unread_mention_tracker.dart`、`apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart`（仅扫描接线）。

**Create：** `apps/mobile_flutter/lib/features/matrix/mention_history_scan.dart`、`apps/mobile_flutter/test/features/matrix/mention_history_scan_test.dart`。

**现存测试需扩展：** `apps/mobile_flutter/test/features/matrix/mention_scan_cancellation_test.dart`、`mention_timeline_order_test.dart`、`unread_mention_tracker_test.dart`、`room_mention_ingest_coalescer_test.dart`（后3均在同test/features/matrix目录），以及 `apps/mobile_flutter/integration_test/cache_first_fast_history_test.dart`。

**最小方法：** 以当前SDK公有timeline ID snapshot/按ID读取创建分页adapter；新接口 `Future<MentionScanPage> next({int limit = 256})` + `Future<void> close()`，page只包含当前页Event与continuation/boundary信息。扫描不再用持续累积的room.getTimeline；先固定scan head/read marker，逐页维护稳定序号，只ingest新页；每页前后请求MaintenanceActivity许可和取消检查，正文消费完释放。普通实时mention ingest保持已有coalescer。初批可以保留旧ID metadata兼容，明确正文有界不等于元数据恒定。

**RED→GREEN：** 10万条fixture reader，累计保留Event≤256；每条payload读取一次；扫描中删除/已查看、读marker不可达、late decrypt、取消/切账号不遗漏不复活；交互锁期间下一页不启动，500ms quiet后再启动；取消后checkpoint不前跳。

**验收：** 1k/10k/100k正文retained数量平台期、处理调用数O(N)；索引/正文保持加密域，不能将m.mentions解密内容发送业务API；先补真实fixture反例再实施，不以“UI200”声称scanner已受限。

### A5. 媒体重复同步hash移出UI调用链

**Modify：** `apps/mobile_flutter/lib/features/matrix/media_cache.dart`、`content_addressed_media.dart`、`media_memory_budget.dart`、`matrix_e2ee_client.dart`（后三同lib/features/matrix）；使用现存 `apps/mobile_flutter/lib/features/media/media_asset_gateway.dart` 的worker校验边界。

**Create：** `apps/mobile_flutter/lib/features/matrix/verified_media_content.dart`、`apps/mobile_flutter/test/features/matrix/verified_media_content_test.dart`。

**现存测试：** `apps/mobile_flutter/test/features/matrix/content_addressed_media_test.dart`、`media_content_dedup_test.dart`、`media_memory_budget_test.dart`、`media_stream_integrity_test.dart`、`media_transfer_integrity_test.dart`（后4同目录）；`apps/mobile_flutter/test/performance/media_cache_metrics_test.dart`。

**最小方法：** 内部不可伪造VerifiedMediaContent工厂从worker得到digest+不可变bytes/受控文件身份，只在受控插入/读取边界复用；缓存flight key、落盘对象名、shared LRU引用复用同一验证结果。保留外部bytes/publicAPI不可信时校验与篡改修复。首批不改ADR-0060加密参数、密文格式、上传合同，不把字符串hash当授权证明。

**RED→GREEN：** 注入计数的hasher，100MiB synthetic cold insert在一条受控内容链最多1次全量digest；UI事件循环心跳能在hash任务期间运行；篡改bytes/伪hash/同hash跨账号不能共享信任，cancel后不重新留存。计时测试须避免脆弱桌面毫秒门禁，用执行上下文/次数证明，真机另测。

**验收：** 真机profile无>8ms UI同步hash片段；冷/热媒体完整性全过；RSS另归B1，不因为hash worker通过就声称峰值解决。与A7都触及media_cache，必须同owner串行或集成者顺序合入。

### A6. 启动deferFirstFrame的可见超时护栏

**Modify：** `apps/mobile_flutter/lib/core/installation_startup_gate.dart`、`apps/mobile_flutter/lib/main.dart`（仅预算/阶段注入）；测试 `apps/mobile_flutter/test/core/installation_startup_gate_test.dart`、`apps/mobile_flutter/test/core/installation_startup_diagnostics_test.dart`、`apps/mobile_flutter/test/core/matrix_startup_client_test.dart`、`apps/mobile_flutter/test/performance/app_startup_trace_test.dart`。

**最小方法：** 给Gate注入launchSurfaceBudget（建议1s）和时钟，预算过后allowFirstFrame并呈现不含账号缓存的安全启动进度壳；继续原single-flight初始化。3s仍pending显示阶段与恢复引导，不直接重开数据库；若要“重试”必须等原owner取消/收敛并持相同DB init lock，不能timeout后平行重复open。现有短启动路径无中间页保持，以免回归已批准的cache-first体验。

**RED→GREEN：** reconcile/start分别永不完成，pump1s后安全壳可见；迟到成功只发布一次；dispose/换账号后迟到成功不显示旧内容；失败/锁屏恢复仍走现有分类。现有测试`local startup has no intermediate checking page`只校验短预算内，不能删除，新增“超预算安全壳”另证行为。

**验收：** 挂起场景不无限停原生launch；没有清缓存/密钥/数据库的自动恢复捷径；首次sync仍非首帧前置；诊断仅固定枚举、不读取秘密。

### A7. iOS可再生媒体目录备份排除，先证明资源属性缺口

**事实与待复现：** `media_cache.dart:230-234`使用Documents/chat-media/v2；`ios/Runner/IOSBackgroundMediaDownload.swift:89-97`只给background-media-v1设置isExcludedFromBackup。普通chat-media是否被实际备份尚未真机核验，不能表述成已外泄。

**Modify：** `apps/mobile_flutter/lib/features/matrix/media_cache.dart`、`apps/mobile_flutter/ios/Runner/AppDelegate.swift`。**Create：** `apps/mobile_flutter/lib/core/media_storage_policy.dart`、`apps/mobile_flutter/ios/Runner/IOSMediaStoragePolicy.swift`、`apps/mobile_flutter/test/core/media_storage_policy_test.dart`、`apps/mobile_flutter/ios/RunnerTests/IOSMediaStoragePolicyTests.swift`。现存回归 `apps/mobile_flutter/test/features/matrix/media_cache_clear_test.dart`、`media_index_phase2_test.dart`、`apps/mobile_flutter/ios/RunnerTests/IOSBackgroundMediaPolicyTests.swift`。

**最小方法：** 第一动作native临时合成目录写入并读回resourceValues证明现有chat-media路径创建默认没有exclude；随后新增固定目录策略，由native自己派生Documents/chat-media，而非Dart传任意路径；创建/首轮升级发现旧目录时设置isExcludedFromBackup并读回。优先原路径打标避免重命名破坏已缓存original/数据库引用。必要失败给有限诊断/重试，不触碰原文件或用户导出相册。

**RED→GREEN/验收：** 老目录、刚创建目录、重开、设置失败/权限拒绝、普通下载与原生后台下载同样标记；不能把排除备份当at-rest加密。保留媒体offline可用、用户导出位置不排除；此前已经形成的系统备份不在本修复可追溯清除范围。iOS真机加密备份抽样仅用合成文件，确认新缓存未进入备份；AndroidallowBackup当前配置独立回归，不为了此项改全应用账户/密钥备份策略。

## 后续：需要设计接口或先补复现的数据面改造

### B1. 活动媒体总字节预算与文件流式加密/上传

**先补复现：** synthetic10/50/100MiB分别send、receive、播放+upload+切房，采Dart/native/graphics/RSS及GC；不能直接把旧K80退出判定OOM。A5只改善CPU，不解决明密文同时存在。

**现存Modify：** `apps/mobile_flutter/lib/features/matrix/media_message_service.dart`、`matrix_outgoing_work_coordinator.dart`、`matrix_e2ee_client.dart`、`content_addressed_media.dart`、`media_memory_budget.dart`；`apps/mobile_flutter/lib/core/native_media_download.dart`；SDK `apps/mobile_flutter/third_party/matrix/lib/src/utils/matrix_file.dart`仅在现有SDK不能流式上传时最小扩展。**Create：** `apps/mobile_flutter/lib/features/matrix/media_transfer_budget.dart`、`apps/mobile_flutter/test/features/matrix/media_transfer_budget_test.dart`。现存测试 `matrix_outgoing_work_coordinator_test.dart`、`media_stream_integrity_test.dart`、`media_load_scheduler_test.dart`、`media_transfer_integrity_test.dart`（test/features/matrix）及 `test/core/native_media_download_test.dart`。

**方法：** 先统一账号owner的活动source/待加密/密文/下载/解码预留，后将大文件转换为受控文件句柄与64KiB级流式读写，引用pin保持可恢复；加密密文格式/nonce/key派生与ADR-0060完全等价，双向兼容需要固定向量和独立安全审查。读取缓存也不能为“播放文件”先重新readAsBytes。真实RSS预算由设备测量定，不把32MiB LRU当全进程上限。

**RED→GREEN/验收：** 多页面并发总预留不得越界；取消/失败释放；100MiB不创建同尺寸Dart数组；旧新版收发互通、SHA/截断/篡改全通过；50轮生命周期无线性增长。若不能证明加密/认证边界未变，按受保护变更先ADR/领域和质量安全评审。

### B2. 媒体附件持久恢复（依赖B1受控文件与A7目录策略）

**事实：** `room_timeline_controller.dart:1745-1753`非文本不入text outbox；`matrix_outgoing_work_coordinator.dart:113-116,284-307`明确in-process。磁盘content cache不是发送intent。

**Modify：** `apps/mobile_flutter/lib/features/matrix/matrix_outgoing_work_coordinator.dart`、`matrix_e2ee_client.dart`、`room_timeline_controller.dart`、`room_page.dart`（只最终集成）；参考现存 `apps/mobile_flutter/lib/core/outbox/outbox_recovery_service.dart` 的账号撤销/恢复模式，不把财务引用当可重放业务操作。

**Create：** `apps/mobile_flutter/lib/core/outbox/media_outbox_store.dart`、`media_outbox_recovery_service.dart`、`apps/mobile_flutter/test/core/outbox/media_outbox_store_test.dart`、`media_outbox_recovery_service_test.dart`、`apps/mobile_flutter/integration_test/media_outbox_recovery_native_test.dart`。**现存回归：** `test/features/matrix/matrix_outgoing_work_coordinator_test.dart`、`outbox_send_flow_test.dart`、`video_forward_backend_test.dart`、`test/core/outbox/persistent_outbox_manager_test.dart`（全以apps/mobile_flutter为根）。

**方法：** 每任务存账号代际、固定txid、目标、受控源file identity/摘要、阶段/失败/重试时间，不存token/room key；本地源使用已有受保护账户存储与明确文件保护，使用schema增量迁移和兼容恢复。persist-before-admission，恢复先验证账号/房间权利再同txid重放；上传已成功而eventACK未知时不换新txid。终态/用户取消后释放pin，未发源不能被可选cache GC删掉。

**RED→GREEN/验收：** 准备/写manifest/上传/发event/ACK落盘每边界杀进程再开，未完成任务可恢复或明确失败、无静默消失，接收端0重复0丢失；换账号/撤权不重放；低磁盘/源丢失有可操作反馈；不得为通过清数据或卸载。

### B3. 提及ID元数据压缩与百万旧ID首次lookup优化

A4正文分页完成后再做tracker存储的完整schema设计；不能简单截断viewed使已读@复活。现存Modify `apps/mobile_flutter/lib/features/matrix/unread_mention_tracker.dart`、`room_mention_store.dart`，先引入稳定scan游标/已完成区间+必要例外事件ID的版本化迁移，证明旧JSON到新状态语义等价。若需要新存储文件，Create `mention_scan_store.dart` 和 `test/features/matrix/mention_scan_store_test.dart`（分别位于lib/features/matrix与test/features/matrix）。

旧历史首次精确lookup另一个独立owner：现存 `apps/mobile_flutter/third_party/matrix/lib/src/database/timeline_id_store.dart`、`apps/mobile_flutter/lib/features/matrix/timeline_migration_reader.dart`；现存测试 `apps/mobile_flutter/test/features/matrix/indexed_timeline_storage_test.dart`、`timeline_storage_migration_test.dart`、`legacy_rollback_rollforward_test.dart`，以及 `apps/mobile_flutter/integration_test/ios_timeline_storage_migration_native_test.dart`。先冷1M不存在/尾部ID重复测量，提取worker扫描成本，再以后台完整member索引或批量预查降低foreground等待；绝不把未建立索引当不存在，保持legacy base/delta/epoch/transaction authority和所有正文。历史5.1/8.8s不是当前设备基准，必须新候选测量。

## 文件所有权与执行顺序建议

- 可并行第一轮：A1（Android owner）、A2（push/AppHome owner）、A3（outbox scheduler）、A6（startup）。这四域主要源码不重叠。
- 下一轮：A4（mention/matrix_e2ee）、A5（media缓存/hash）、A7（iOS backup）中A4/A5共享matrix_e2ee，A5/A7共享media_cache，不能同时编辑；各自产出最小patch后由单一集成owner顺序落入。A2与A7如都改AppDelegate也需串行归属，尽量将新增native政策放独立文件。
- B1先定义稳定文件/预算接口，再B2持久恢复。B3元数据与legacy索引可分两个owner，避免并行修改room_mention_store。
- 任务单位均有独立RED→GREEN、现存回归、规格符合性然后质量/安全审查；任何新protected变化先ADR。此处只给方案，不自动开始实施、推送通知、构建、安装或发布。

## 最小验证执行说明（实施期才运行）

先锁候选SHA/依赖、Flutter/Java/OS及实际导入路径；命令统一pwsh.exe+UTF8无BOM与Python UTF8。在 `apps/mobile_flutter` 下按每任务列出的已存在/新建test路径执行 `flutter test <path>`，先看真实失败原因再改实现；Android在 `apps/mobile_flutter/android` 使用现有 `gradlew.bat :app:testDebugUnitTest`并指定受影响测试类；iOS以现存 `.github/workflows/ios-compatibility.yml` / `.github/workflows/ios-enterprise-package.yml` 的原生测试编排补新测试入工程，不用Windows结果冒充iOS。

最终共享源码冻结后统一一次analyze/适用全量门禁；`scripts/verify.ps1`先环境预检，缺.env则记录不能执行并沿工作流拆分适用门禁，不能导入生产秘密。复用输入相同的已有完成门禁，不按每小任务重复整套构建。最终APK/IPA发布是后续独立授权与签名/保数据真机门禁，不属于本次方案。

**第一批验收表应分四列：** 代码单测/原生受控场景、当前可用推送通道实测、未开通OEM外部依赖、实际真机未测项。服务端健康、pusher存在和UI本地显示不能互相替代，更不能证明双端送达；双端tap→持久化→serverACK→receiver解密/可见要按合成账号分别记录。
