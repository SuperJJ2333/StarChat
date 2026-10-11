# 客户端端到端只读评审：同步、历史、内存、媒体与启动

审查日期：2026-10-11，Asia/Hong_Kong。产品源码基线 main `5c83a08a09b985146bc507a1608cb2153d361e48`，开始时 `git status --short --branch` 只有 main ahead 36，无产品工作区改动。没有 `.codegraph`。本任务仅写本文件；没有构建、安装、清理、运行测试、读取设备消息、访问生产或读取秘密。阶段精确耗时未计时，未知；本次为静态调用路径核查及既有证据复核。

以下源码路径均相对 `D:/pythonProject/outsource/StarChat/`。行号对应本次 main；数字性能结果来自明确标识的历史验证报告，**不是本次测量，也不是当前真机生产测量**。建议验收阈值是待采用的初始目标，应与主报告统一，不能当作既有达标结果。优先级：P1 是下一轮性能/可靠性重点，P2 是需要安排的结构与度量改进；没有证据将以下问题定为当前生产 P0 故障。

## 总体结论

main 已包含缓存列表先发布、缓存 head 气泡先发布、可选关联房间/提及恢复后置、有界 SDK/UI 时间线、顺序稳定的本地回声、持久文本 outbox、原生加密历史 worker 和媒体缓存预算。这些是已有能力。旧 2205 的普通 sync 等完整迁移导致空列表问题不能继续按当前源码缺陷汇报。仍有明确热点：首次旧历史精确成员定位、独立提及 scanner 的无界正文累积与重复遍历、媒体任务进程死亡恢复缺口、全量字节内存和多次同步哈希、跨房发送队头等待，以及首帧长期 defer 的本地启动链。

## 10 项核心发现

### C1 / P1：旧格式百万历史的首次陌生 ID 精确定位仍是全扫描

- **现象/影响**：有缓存首屏已能先出现，但第一次定位陌生历史 ID、查重或依赖它的同步/写操作仍可能等待数秒。不能把首屏快速等同于任意历史操作恒时。
- **当前源码证据**：`apps/mobile_flutter/third_party/matrix/lib/src/database/timeline_id_store.dart:542-581` 未命中索引/成员提示时 `_membership` await `_legacyPage(findEventIds:[id])`；`:688-727` positions 同样走精确旧源查询；`:799-845` 独立串行 membership lane。`apps/mobile_flutter/lib/features/matrix/timeline_migration_reader.dart:519-589` 无完整 Bloom 加速状态时从 ordinal/byteOffset 0 开始；`:610-673` 逐 ID 扫描、建立 checkpoint/Bloom 后才能证明未知 ID 不存在。生产路径在 Isolate 中，见 `:379-394`，不是主 UI isolate 整段 JSON 解码。
- **历史实测**：`docs/verification/2026-10-09-mobile-responsive-maintenance.md:27`：debug2208，1M 首页201ms，首次陌生ID5131ms，第二次212ms；较新的 `docs/verification/2026-10-09-cache-first-fast-history-emoji-recents.md:44`：debug2212首次精确 ordinal约8.8s。两次场景/输入不同，不能说已测出稳定回归幅度。
- **触发/复现**：在专用合成账号导入 1M ID 的 retained legacy JSON、无成员/Bloom加速状态；查询尾部存在 ID 和不存在 ID；同时发送新消息/切房，分别测首次和第二次，重开后复测。只记录行数/阶段耗时，不导出正文。
- **根因/优化**：旧源需要精确成员证明，当前加速器首次建立仍 O(N)。继续后台建立可恢复完整成员索引、批量预查陌生 ID，提供查询取消/进度与交互优先；不能把“索引尚未找到”当不存在破坏去重/顺序。
- **验收**：索引完成后1M随机查询p95≤100ms；冷查询不得阻挡可见列表/切房/输入，取消反馈≤200ms；统计冷/热lookup、sync processing分别的p95/p99，重复/丢失/错序均0。冷全量建索引可有明确进度，不要求虚假恒时。

### C2 / P1：提及 scanner 使用独立无界 Timeline，历史正文累积，遍历成本可近二次增长

- **现象/影响**：长时间未读大群后台恢复 @ 时，即使主聊天窗口≤200行，scanner仍可能保留整个未读区间的 Event/解密内容；连续60条分页，每轮又遍历累计 events，CPU和内存随未读量增长。
- **当前源码证据**：`apps/mobile_flutter/lib/features/matrix/room_mention_store.dart:214-261` `room.getTimeline()` 后不断 `requestHistory(historyCount:60)`，没有 `enableResidentWindow`，直到旧读标记/耗尽才取消订阅；`:86-119` 对累计events做注册和 `ordered.reversed`，`:237`每页再次ingest。SDK `apps/mobile_flutter/third_party/matrix/lib/src/timeline.dart:103-120` 默认 `_residentEnabled=false`；`:552-581` 非有界路径以events.length分页并 `events.addAll(eventsFromStore)`。主房间的resident启用不能覆盖这个独立scanner。
- **历史证据**：缓存优先报告 `docs/verification/2026-10-09-cache-first-fast-history-emoji-recents.md:44` 已明确 scanner完整未读正文风险未改；本轮无RSS实测，不能宣称已发生OOM。
- **触发/复现**：合成未读群1k/10k/100k消息，read marker在最早页或已不可访问；触发scan，同时IME开合、快滑、切房。每页采样Event对象数、retained heap、ingest总耗时，比较1万→10万曲线。
- **根因/优化**：UI窗口有界，但提及恢复保留的是独立累积列表。改成固定页扫描、仅持久化必要提及ID/顺序/游标，及时释放页面正文，并纳入交互维护预算。保留精确提及、撤回与已查看防复活语义。
- **验收**：未读10万条时scanner常驻正文≤256条或等价固定上限；RSS增量随N进入平台期而非线性增加；输入/切房期间暂停扫描，取消≤200ms；扫描完整性、无重复提醒与隐藏/撤回正确率100%。

### C3 / P2：提及持久状态仍随全历史扩张，频繁同步JSON序列化与全量偏好写入

- **现象/影响**：scanner结束释放Timeline以后，ID级状态仍不有界；长时间使用大群后prefs体积和每次save成本可持续增加，放大启动、切房和同步阶段CPU/写入量。
- **证据**：`apps/mobile_flutter/lib/features/matrix/unread_mention_tracker.dart:23-40` 包括pending/viewed/order/timelineOrders；`:56-76` 注册所有所见ID；`:131,148` viewed仅增加；`:164-177,210` 全量 `jsonEncode(toJson())`。`apps/mobile_flutter/lib/features/matrix/room_mention_store.dart:26-27` 账号房间state/open future常驻map；`:198-207` 每次changed后完整encode+`prefs.setString`。WeakReference观察缓存有界（`:114-145`）是优点，但不约束上述tracker状态。
- **触发/复现**：合成群逐批积累10万/100万ID，标记查看、撤回、重新登录，记录state编码字节数、encode耗时、写入次数；核对重复sync不复活已查看提醒。没有现成实测，本项为可达代码风险。
- **根因/优化**：逐事件全历史关系保存在单一JSON，而不使用游标/区间与增量表。采用有界最近rank窗口、已完成区间/游标和必要例外ID持久化，合并save，不能直接截断viewed造成提醒复活。
- **验收**：steady state编码/写入不随全部历史线性增长；单次UI isolate序列化≤4ms；后台扫描每固定页/时间窗合并写入；账号隔离、重启后已查看不复活全通过。

### C4 / P1：非文本发送不具备持久 outbox 的进程死亡恢复保障

- **现象/影响**：图片/语音/普通文件或视频显示“正在发送”后，切到后台被系统杀进程，未完成任务可能消失，不能按文本outbox一样承诺自动续发。磁盘媒体缓存存在不等于已持久化发送意图、目标房间和txid。
- **当前源码证据**：`apps/mobile_flutter/lib/features/matrix/room_timeline_controller.dart:1745-1753` 明确仅非空文本入journal，其他kind走内存路径。普通附件真实入口 `room_page.dart:2234-2242` 使用kind image/file+内存闭包；`:2821-2836` 是页面Future队列。视频/多目标owner也明确 `matrix_outgoing_work_coordinator.dart:113-116,284-307` “in-process only”，jobs为内存map。文本对照 `core/outbox/persistent_outbox_manager.dart:376-395` 启动把在途行重置queued并同txid恢复。
- **触发/复现**：专用测试账号发送文本、语音、100MiB文件和视频，各在准备/上传/Matrix event发送前后杀进程并保留数据重启；核对未完成气泡、任务、原txid和收件端最终事件数量。此轮未执行，不宣称真实用户已经丢消息。
- **根因/优化**：非文本包含带外载荷，现有文本journal不能重建它。新增账号隔离的持久媒体任务manifest与受控文件引用，保留原txid、阶段、重试状态与授权检查；恢复时必须重新校验目标/权限，成功后清理临时源。
- **验收**：每阶段故障注入100次，重启后任务可恢复或显示明确可操作失败；无静默消失、无重复事件；登出/换账号不重放旧账号任务；未授权发送0；临时文件无孤儿增长。

### C5 / P1：媒体缓存预算没有覆盖在途完整明文、密文和解码资源的总峰值

- **现象/影响**：单个100MiB合法文件已超过32MiB可选缓存预算，读取、准备加密和上传可同时持有明文/密文；native下载也最终完整readAsBytes交给Dart。多页面/前后台工作叠加时进程RSS不能由缓存预算直接推断。
- **证据**：`media_message_service.dart:17-20,130,217-265,305-321` 100MiB上限、服务实例3槽、整文件readAsBytes；当前同页面 `_enqueueMedia` 串行（`room_page.dart:2821-2836`），因此**不能据3槽断言当前同页面必有300MiB明文同时存在**。`matrix_e2ee_client.dart:9344-9418` 原始bytes/处理结果/媒体文件/缓存/加密结果沿调用链保留；`content_addressed_media.dart:175-205,211-251` compute接收完整bytes，prepared file同时保留bytes与preEncrypted；`core/native_media_download.dart:198-212` native落盘完成后整文件readAsBytes；`content_addressed_media.dart:38-60` 普通加载走整块SDK解密。`media_memory_budget.dart:19`32MiB仅LRU引用；`core/media_resource_policy.dart:6-7,18-19`64MiB ImageCache明确不含live/native/GPU；outgoing coordinator128MiB是source预算（`:284-305`），不是全进程预算。
- **触发/复现**：低内存真机分别执行100MiB文件发送、大图打开、视频播放+后台上传+切房；记录Dart堆、native heap、graphics、RSS/PSS、GC暂停、OS退出原因，比较单任务与叠加任务。此轮未测峰值，不能归因旧K80退出为OOM。
- **优化/验收**：优先引入文件/流式加密上传、流式校验、TransferableTypedData或避免重复数组；账号owner统一活动字节预算与并发降级，含下载/上传/转码。目标建议低内存档活动媒体字节≤64MiB（或单个大文件专用流式通道）；RSS硬阈值需按设备基线确定；连续50轮媒体切房后台恢复无线性增长、无LMK/崩溃。

### C6 / P1：媒体缓存链仍对同一完整数组多次同步SHA-256，worker加密未消除主调用isolate CPU长任务

- **现象/影响**：网络已完成/本地已有媒体时，发送或首开仍可能卡住输入与帧。磁盘异步和加密compute不能覆盖缓存层同步hash。
- **证据/可达链**：UI `room_page.dart:2234-2242` → `media_message_service.dart:253-254` → `matrix_e2ee_client.dart:9401-9418`先await cacheOutgoingMedia再prepare；`media_cache.dart:1564`先同步digest，`:1446`verify，`:551-553`store中verify+flightKey digest，`:590`_store再次digest，`:1485`返回数组再次verify，`:1142-1144`内存canonical阶段可能再digest。`content_addressed_media.dart:129-133`verify为同步crypto.sha256.convert。相对地，`:175-180`MediaEnvelope的hash/encryption已compute；没有在上述普通UI调用外层发现Isolate包裹。
- **触发/复现**：10/50/100MiB合成随机文件，冷缓存发送/接收各一次；DevTools CPU/Timeline定位同步hash连续片段，同时50次IME开合。分别统计hash次数/总bytes/时长与帧，缓存热命中另记。不以静态代码推造ms。
- **根因/优化**：不同缓存/校验层重复证明同一不可变内容。把一次worker流式计算得到的可信digest/不可变bytes provenance沿边界传递，仍在不可信入口做校验；不要为优化省略完整性检查。
- **验收**：100MiB操作不在UI isolate出现>8ms的hash片段；同一受控不可变数组最多一次全量digest，必要跨信任边界单独记录；冷/热内容校验、篡改修复、跨账号隔离继续通过。

### C7 / P1：后台outbox跨房间顺序调度，慢房间/未建房解析会延后健康房间发送

- **现象/影响**：A房网络/授权/房间租约卡住时，B房即使可发送也需等待；大量已打开房间内pending行会逐条等各自操作预算，形成跨房队头阻塞。
- **证据**：`core/outbox/message_send_scheduler.dart:57`30s默认operationTimeout；`:256-264`先await全部unbound解析再组房；`:315-365`逐peer串行解析；`:293-302`房间逐个await；`:420-439`已打开房间每行逐个await，30s后仍继续同房下一行；lease路径`:602-610`单条超时才释放调度机会给下一房。安全点：超时不会释放实际claim，迟到请求仍归原owner。
- **触发/复现**：用可控Completer的A sender永不完成，A有3行，B有1行即时完成；另加未绑定receiver解析hang。调用scheduler.drain，测B first dispatch延迟、A在途count/txid。现有测试文件含timeout/迟到ACK，但本轮未跑；不把30s参数当实测延迟。
- **根因/优化**：按房间分组后全局串行，无公平调度。改为每房保序、跨房小并发/轮转；unbound解析单独有界lane。保留原txid、原子claim、权限和账号generation隔离。
- **验收**：A挂起时B≤200ms进入传输（不含B自身网络）；总并发≤配置小值；同房顺序、重复txid、迟到ACK与登出撤销全部正确，A不因超时重复发送。

### C8 / P1：首帧被本地启动完整链defer，挂起操作没有可见恢复界面或时间上限

- **现象/影响**：缓存优先解决了首sync依赖，但本地钥匙/身份检查/数据库恢复迟滞时仍会长驻原生启动画面，用户无阶段提示和重试入口。这里讨论当前代码结构风险，不把旧iOS2205故障直接归为此根因。
- **证据**：`core/installation_startup_gate.dart:38-45` deferFirstFrame；`:76,96-102`依次等待reconcile、widget.start，完成才allowFirstFrame；`:121-122`等待态空Widget；没有时间阈值释放首帧。`main.dart:91-116`在runApp前串行读取本地偏好；`:130-161`startApplication内等diagnostic salt/device key/openStartupMatrixClient；`matrix_client_factory.dart:943,1027-1035`SDK初始化仍等本地库恢复，但明确 `waitForFirstSync:false`。历史100房/10×25万旧索引恢复约2.46s见缓存优先报告`:44`，非当前真机启动p95。
- **触发/复现**：在现有 `installation_startup_gate_test.dart`夹具中把reconcile或start换为永不完成Completer，推进10s；真机用合成大库测冷启动/锁屏后恢复与存储慢情况。验证首帧释放/恢复界面，不清用户数据。
- **优化/验收**：保留身份检查，但规定launch画面预算，超时先给不可访问聊天内容的安全进度壳/重试取消，按阶段计时；重试避免重复open/client泄漏。建议首个可交互安全壳≤1s、缓存会话可用p95≤1.5s（设备分档）；任一hang≤3s出现明确可恢复状态，绝不显示错误账号缓存。

### C9 / P2：当前发送ACK与“visible”诊断主要证明发送端/服务器接收，不能代替双端送达时延

- **现象/影响**：服务器已返回event_id而收件端尚未sync、解密、发布甚至在后台；若把此ACK计为“收发已完成”，会漏掉收件端积压、密钥等待和后台恢复问题。
- **证据**：`core/outbox/message_send_scheduler.dart:548-561` 非空eventId即sent并标ack；`core/performance_trace_model.dart:663-674` messageSend定义matrix_send、send_to_visible、send_to_publish等发送操作阶段，没有在这一条发送trace中建立收件设备解密/首帧确认。`room_timeline_controller.dart:1045-1064`已区分SDK本地echo与sync权威行并保持顺序，是正确实现；这项是验收/度量边界，不是要求把网络ACK错误地改为已读。
- **触发/复现**：双测试设备A发、B分别前台/后台/断网/缺密钥；A已经ACK后继续记录B sync收到、解密完成、UI发布/可见的时间。使用合成事件和本地一次性关联键，禁上传真实正文/身份。
- **优化/验收**：测试仪器分别给出tap→持久化、tap→server ACK、server ACK→B decrypted、tap→B visible的p50/p95/p99；区分sent/delivered/read，不承诺后两种不存在的业务语义。建议健康Wi-Fi双前台text tap→B visible p95≤1s，弱网按受控RTT单独定额；乱序/重连/重发唯一事件比对0丢0重复。

### C10 / P1（证据缺口）：真实设备release/弱网×连续快滑×后台恢复组合尚未覆盖，现有优秀单项数据不足以关闭整体性能风险

- **历史证据**：`docs/verification/2026-10-09-cache-first-fast-history-emoji-recents.md:18-24`5757 Flutter、377边界、原生缓存15+独立连续1、30次10000px/s锚点<1px、emoji6与旧历史24，是强单项证据；`:44`明确缺Redmi/弱网release和iOS性能、弱网响应与持续手势组合；debug维护最高build314ms、emoji434ms。`mobile-responsive-maintenance.md:27`debug p95约21.7ms；不能与release设备帧预算直接同义。相同报告的历史渠道版本不是今日生产版本，本轮未核实生产。
- **影响/复现**：真机CPU、RAM、GPU、系统后台杀进程、iOS Keychain/SQLCipher及移动网络与x64模拟器不同。用两档Android（含问题机型）+两档iOS，在最终候选来源/SHA上跑：100房×长历史、双端连发、30次快滑+50次IME、A→B→A、限速/断网恢复、媒体叠加、后台10/30分钟返回和保数据升级。
- **根因/优化**：测试覆盖组合与部署身份尚未闭合；不要再重复未变源码等价单测，优先补真实设备profile与稳定release观测，按失败阶段定位。
- **验收**：分别报告UI/raster p50/p95/p99及>50/100/700ms数量、冷/热启动、heap/native/GPU/RSS峰值、50轮后稳态斜率、OS退出原因、丢样比例。建议60Hz场景p95≤16.7ms、p99≤33.3ms且>100ms0；长历史锚点≤1px、UI≤200、SDK普通timeline≤1000、无重复/丢失、账号隔离和key权限全通过。若未达阈值保留具体未完成项，不能用平均值或最后exit0掩盖失败。

## 已确认能力与不能重复报的问题

1. **缓存优先存在**：SDK `third_party/matrix/lib/src/client.dart:2134-2156`先安装cached room list，再unawaited修复preview，带账号/DB/rooms身份校验；`matrix_e2ee_client.dart:2138-2145`普通入房先主timeline、关联源后台attach，仅显式跨源anchor需要等待。
2. **有界正常时间线存在**：SDK `timeline.dart:120-150`在确认持久化可重载后启用≤1000；UI `room_timeline_controller.dart:1075-1076`≤200；历史正文仍保留本地、未靠丢历史优化。独立提及scanner是例外，不能据它说整个主时间线无界。
3. **弱网顺序与迟到ACK保护存在**：`room_timeline_controller.dart:1036-1105`保持权威SDK顺序、pending原插入位置；`:1794-1818`20秒是UI观察预算，原请求和durable claim不释放；scheduler`:428-437,602-609`保持同样约束。不能把20秒UI超时直接报为重复发送BUG。
4. **文本恢复存在**：持久化、同txid、原子claim、启动复位和server Retry-After/backoff（三次2/5/15秒）在outbox源码可见；是否所有双端实际投递SLO满足需C9实测。
5. **媒体生命周期已有系统设计**：32MiB共享encoded LRU、64MiBdecoded cache、384MiB账号/1GiB设备磁盘quota、account generation取消、source flight合并、视频持久文件/pin与页面dispose均存在。不能把历史临时文件泄漏直接当当前事实；磁盘quota逐对象扫描与iOS备份由主审单独分析。
6. **数据库同步IO判断要准确**：`timeline_migration_reader.dart`的sqlite3.select/FFI BLOB/readSync位于explicit worker（`:379-394`等）；当前生产工厂使用 `createDatabaseFactoryFfi`+await数据库API，不能仅因找到SQL/同步FFI名称宣称在UI主线程IO。可确认的主调用isolate同步大对象工作是C3 JSON与C6 hash。

## 已核查但不列为当前核心缺陷：旧明文库转换

`third_party/matrix/lib/src/database/sqflite_encryption_helper/io.dart:121-141`存在export→assert→delete原文件→copy临时文件的底层转换流程，值得专用故障注入。但当前普通启动受 `matrix_client_factory.dart:449-452`阻断未获授权的明文迁移，`core/matrix_startup_client.dart:43-51`可进入safe shell；`local_identity_preflight.dart:153-163`发现 `.encrypted`残留会fail closed。故不能按“所有用户启动都会delete数据库”的P0报道。认证后的scope授权路径 `matrix_client_factory.dart:389-390`会允许后续open，需将中断恢复/完整性验证交给专属存储任务，保留原始副本，不做本轮现场试验。

## 下一步可执行工作

主报告优先编排 C1/C2/C4/C6/C7/C8，再由最终候选SHA上的真机组合验证C5/C9/C10；C3可与C2一并设计。需要补的数据：当前main精确输入的真实设备指标、双方安装包身份、交互与后台阶段的内存分解、媒体任务进程死亡结果、跨房队列公平性时延、双端ACK→解密→可见分布。所有复现使用合成账号与固定资产；不上传消息正文、token、真实账户标识。
