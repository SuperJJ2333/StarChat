# ChatFlow 全链路性能诊断

## 代码审计（2026-09-25，实施前）

审计基线为 `2442f0ab`。仓库没有 `.codegraph/`，因此按仓库规则使用 `rg` 定位。扫描了客户端 `core`、`matrix`、`contacts`、`moments`、`finance`、`profile`，以及 `services`；涉及 `Stopwatch`、`PerformanceMetrics`、`ChatDiagnostics`、`debugPrint`、`Duration`、`elapsed`、`timeout`、`sync`、`upload`、`download`、`getStats`、HTTP、数据库、导航及 `RoomPage` 的文件共 98 个。主工作区有其他任务的未提交改动，本任务使用独立 worktree，不把这些改动视作已交付基线。

| 模块 | 现有监控 | 缺失监控 | 重复风险 | 接入位置 |
| --- | --- | --- | --- | --- |
| 客户端核心 | `PerformanceMetrics` 有界样本、P50/P95/P99/MAX、帧 build/raster 预算；`ChatDiagnostics` 有界聚合、会话隔离和后台上传 | 用户操作共享 ID、阶段记录、操作与慢帧关联、分类 | 高：不能另建帧采集器或上传通道 | `core/performance_metrics.dart`、`chat_diagnostics.dart`、`chat_diagnostics_scope.dart` |
| 会话打开 | `RoomOpeningPolicy` 已有 source/outcome，`RoomNavigationCoordinator` 合并导航；本地快照先显示 | 身份/本地房间/导航/首帧/attach/timeline/sync 共用 ID | 高：`Navigator.push` Future 在退页才完成；不可当打开耗时 | `app_home.dart` 的 `_openMessage` / `_openManagedRoomRoute`，`room_page.dart` 的 `_load`，pending conversation 路径 |
| 消息发送 | 持久 Outbox；发送准入和 Matrix 发送已有慢/错诊断 | composer→persist→admission→send→ack→visible、重试和最终状态 | 中：不得改变 Outbox/txid 语义 | `room_timeline_controller.dart` 的 `_dispatchSettled`、`room_page.dart` 提交入口 |
| Matrix sync / 生命周期 | `MatrixSyncPhaseMetrics` 已测 response wait/processing/cleanup；Watchdog 已有软唤醒/硬重启；网络状态机独立 | 完整周期、错误/重连计数、健康年龄、resume 各里程碑 | 高：Matrix 断线不等于设备离线 | `matrix_sync_phase_metrics.dart`、`matrix_sync_watchdog.dart`、`app_home.dart` resume |
| 媒体 | memory/disk/download 命中计数、`MediaLoadScheduler` 容量与队列、`VideoPosterDiagnostics` | 排队/下载/解密/解码/转码真实分段与资源桶 | 高：当前解密回调含下载，不能把整体标为解密；队列 getter 不能逐事件枚举 | `media_load_scheduler.dart`、`media_cache.dart`、视频准备/发送入口 |
| 通话 | `CallDiagnostics` 的呼叫阶段；`CallQualityMonitor` 解析 getStats、RTT/jitter/包数/TURN | 共享操作 ID、质量样本上限及安全摘要 | 高：不重复解析 getStats；不记录 ICE/SDP/IP | `call_diagnostics.dart`、`call_quality_monitor.dart`、`call_controller.dart` |
| Business API 客户端 | 共用 `_authorized` 含 401 重试；独立诊断上传避免认证递归 | 总请求耗时、状态、类别、重试、精确错误种类 | 高：逐方法 Stopwatch 会遗漏直接 `_client` 调用 | `core/business_api_client.dart` 的 HTTP client 与 `_authorized` |
| 聊天列表/联系人 | 本地快照先显示、后台刷新 | route enter / first frame / content ready 与本地/远程分开 | 中：不可让远程刷新阻塞首帧 | `matrix_home_page.dart`、`contacts_page.dart` |
| 朋友圈/搜索 | feed 缓存与后台刷新；搜索本地批次和历史回填 | feed/cache/refresh、搜索 DB/渲染耗时与结果桶 | 高：不能逐动态无限上报或记录关键词 | `moments_page.dart`、`global_search_page.dart`、`global_search_controller.dart` |
| 钱包/资料 | `WalletEntryStore` 与 profile controller 已区分缓存和刷新 | 首帧、缓存内容准备、远程刷新阶段 | 高：性能接线不可改变财务状态或缓存策略 | `manual_wallet_page.dart`、`wallet_entry_store.dart`、`profile_page.dart` |
| Business API 服务端 | `tracing.py` 全局 trace ID；严格诊断接收端；media metrics 有界 512 样本 | 路由模板请求耗时、DB 查询/池指标、分位数 | 高：不得记录实际路径、SQL/参数，不能伪造连接等待 | `app/core/tracing.py`、`database.py`、`modules/media/metrics.py`、`api/client_diagnostics.py` |

现有 `RoomOpenDiagnostic`、聊天首页及导航日志有原始 room ID 的调试打印。本层绝不复制其内容；相关日志需要单独审查和移除。当前 `http` / Matrix SDK 不能可靠提供 DNS、TCP、TLS、TTFB 全阶段，字段应保持 `null`，不得估算。现有媒体回调若同时做下载与解密，必须先在真实边界分段，否则仅记录总耗时。

## 诊断模型

```text
用户操作
  ↓
Client UI → Local Storage → Network → Business API / Matrix
  ↓                              ↓
Flutter frame                 Database / Storage
  ↓                              ↓
Render ← Response ←───────────────┘
```

## 数据流与读取方式

```text
用户动作 / 系统状态变化
  ↓  同一个随机 UUID v4 operation_id
PerformanceTrace.start → mark(封闭阶段枚举) → finish
  ├─ PerformanceMetrics：现有 FrameTiming、帧预算、操作/阶段有界样本
  │    └─ ext.chatflow.performance：本地 snapshot、P50/P95/P99/MAX、最近操作及瓶颈分类
  └─ ChatDiagnostics：现有会话隔离、采样、批次/退避、后台上传
       └─ POST /api/v1/client-diagnostics：既有认证/限流/16 KiB 上限
            └─ Business API 进程内 route-template/数据库/媒体分位数快照
                 └─ GET /api/v1/diagnostics/performance（受维护令牌保护）

Business API 请求启用诊断时额外发送 `X-ChatFlow-Performance-Id=operation_id`。服务端仅把它放在最多 256 条进程内 `recent_operation_requests` 窗口，用于与同 ID 的客户端请求记录核对 route template、状态码和服务端请求总耗时；既有 `X-Trace-Id` 及金融/资料审计保持独立。诊断关闭时不添加此头。
```

页面已明确归属的初始请求和刷新请求在异步子操作作用域内生成 `api_request` 记录，与父页面操作共享 UUID v4；作用域按 Dart Zone 隔离并验证同一 recorder、活跃状态与账号代次。一次刷新是新的页面操作，与此前已完成的缓存首屏操作使用不同 ID；其内部 HTTP 请求沿用刷新 ID。独立发起的 API 请求仍各自生成 ID，不能凭时间相近强行关联。Matrix `/sync` 是全局循环，独立 `matrix_sync` 记录有自己的 ID；聊天页在其活跃会话 trace 上观察同一状态流，直接记录实际看到的同步阶段，所以聊天打开本身不依赖跨记录猜配对。

`mark` 仅在内存中写入枚举键和单调时钟偏移；容量耗尽或诊断关闭时不创建随机 ID、不启动请求、不查询数据库、不写文件。`finish` 幂等，废弃 trace 可 `dispose`；切换账号清除未完成 trace，旧会话结果不能进入新会话。操作同时最多 100 个，每个最多 64 个阶段；`PerformanceMetrics` 的样本、`ChatDiagnostics` 的待发数据及服务端各指标序列均有上限。排序和 JSON 编码只在读取 snapshot 或后台批处理时发生，不在 `mark` 路径。普通 Release 的完整本地指标默认关闭；profile 或 `CHATFLOW_PERFORMANCE_METRICS` 才打开本地详细指标；认证会话的已有 `ChatDiagnostics` 保留低频聚合与抽样。

消息发送的同进程等待网络重试最多保留 5 分钟，并受 active trace 容量限制；超过窗口先输出 `waiting_network`，后续 ACK 不能改写已完成记录。Outbox 仍负责跨页面/进程可靠送达，但新 controller 或重启后无法恢复原随机短期 operation ID；pending conversation 页键入的 Outbox 消息也不在 RoomTimelineController 的 composer→ACK trace 范围。单一 `matrix_send_start/finish` 阶段只代表首个实测尝试，不把离线等待时间当成 Matrix 发送耗时。消息 `timeline_visible` 是控制器发布模型，不是像素首帧。

本地 `snapshot().recentTraces` 为单条诊断记录增加 `timings_ms` 和纯函数推导的 `bottleneck`；上传记录保留相同操作 ID 与实际阶段偏移，接收端可按相同边界计算区间。没有起止两个真实标记时，区间键缺席，不能解释为 0。`conversation_open` 的 `sync_wait_ms` 仅在本地 timeline 和远端 sync 均被观察到时产生；远端早于本地完成则为已测得的 0。只有本地已就绪而没有 sync 证据时，该字段保持缺席，状态为 `waiting_network` 或相应终态。

## 已接入的操作与阶段

| 操作 | 真实测量边界 | 诊断用途 |
| --- | --- | --- |
| `app_startup` | Flutter binding 初始化后至首帧 post-frame | 仅在 profile/诊断指标启用时写入本地 `PerformanceMetrics`，不跨账号上传；无内容 ready 信号就不填 |
| `conversation_open` | 用户点击、身份、本地房间、route push/首帧、room lease attach、本地 timeline、真实 sync waiting/processing/cleanup/finished | 同一 ID 区分页面/房间/timeline/Matrix 等待与处理；`opening_source` 为本地房间或 pending conversation |
| `app_resume` | 后台→前台后的首帧、Matrix connected、sync finished、可见房间 ready；实际 soft kick/hard restart、sync error/reconnect 增量和最近健康 sync 年龄 | 排查切后台回来慢；缺失的里程碑与无健康同步证据保持缺席 |
| `message_send` | composer submit、Outbox 落盘、发送准入、Matrix send 起止、ACK、timeline visible | 同一匿名 ID 对应本进程有界观察窗口内的发送与重试次数、`sent/waiting_network/rejected/failed/cancelled` |
| `matrix_sync` | SDK waiting/processing/cleanup/finished/error 状态 | response wait 与本地 processing 独立，完整周期与错误/重连计数可读 |
| `media_load` | Scheduler 排队、active/queued/video active 与封闭优先级、cache 命中/未命中、真实媒体加载起止 | 区分排队与缓存；当前 SDK 把下载和解密合并，不能单凭此项断定网络层 |
| `recent_pictures_load` | 最近图片 route enter、首帧、已知内容 ready | 首帧与列表资源就绪分开 |
| `video_prepare` | 选取/验证、准备/转码/封面、加密准备、SDK 发送终态 | 发送视频中转码与合并上传/事件发送边界 |
| `video_poster` | 现有封面管线的内存/磁盘、服务端封面、本地帧路径 | 来源用封闭枚举区分；服务端封面不在无下载边界时虚构下载时间 |
| `call_setup` / `call_active` | 信令/ICE/连通状态；现有 WebRTC getStats 的 RTT、jitter、包数、TURN/协议 | 通话建立与通话中质量；丢包率只由同一样本真实包数导出 |
| `api_request` | Business API 共用 HTTP seam，含同一逻辑请求的认证重试 | endpoint 类别、方法、状态、耗时、错误与重试；不包含 URL/query；与服务端短期窗口用同一随机 ID 关联 |
| `chat_list_load` / `contacts_load` / `moments_load` / `wallet_load` / `profile_load` / `search_page_open` | route enter、首帧、本地缓存内容就绪、后台刷新完成 | 区分页面可见与内容可用，远程刷新不阻塞已有缓存首屏 |
| `search` | 本地内存索引扫描、真实数据库调用处、结果渲染、结果数量桶 | 不收集关键词；只有实际数据库边界才标 `database_search` |

页面图片等高频项沿用现有媒体计数/诊断，不会为每条朋友圈动态无限建立 trace。本文的“本地 timeline”是房间本地恢复总耗时，不等同于 SQLite 单条 query；Business API 的 SQLAlchemy cursor hook 才是服务端 SQL 执行耗时。

### 聊天打开的一条记录

```text
operation=conversation_open  operation_id=<random UUID v4>
opening_source=local_room  lifecycle=foreground
conversation_open_total_ms=1830  identity_lookup_ms=12
local_room_lookup_ms=35  navigation_ms=80  first_frame_ms=120
room_attach_ms=18  timeline_local_ms=91  sync_wait_ms=1490
slow_frame_count=0  transport_available=true  service_reachable=true
matrix_state=connecting
```

上述数值只演示字段与推理；它们不是项目实测结果。`first_frame_ms` 是点击至首帧；`navigation_ms` 是 route push 至首帧，二者并非可相加分段。`timeline_local_ms` 以房间页本地恢复开始至内容 ready 为界。pending conversation 先显示 pending 页时，首帧属于该页；房间 attach/timeline/sync 继续使用原 ID。若 Matrix 已连通，`remote_sync_ready` 取真实已知状态，不凭空等待一个新的 `/sync` 周期。若房间页完整观察到同一次同步的 `waitingForResponse → processing → cleaningUp → finished`，同条记录额外输出 `sync_response_wait_ms`、`sync_processing_ms`、`sync_cleanup_ms`。中途订阅时没有真实 waiting 起点，response wait 保持缺席；错误或重试不跨周期拼接阶段。

## 诊断状态、分类与阈值

网络三层分别记录：`transport_available` 为设备传输可用的已知状态；`service_reachable` 为已有服务访问的证据；`matrix_state` 为 Watchdog 所见 Matrix 连接。未知保持 `null`/`unknown`。Matrix disconnected 不能推断设备离线。HTTP 只在当前技术栈真实提供时记录总耗时、状态码、超时/错误类别与重试；DNS、TCP、TLS、TTFB 分段没有可靠 hook，保持 unsupported/null。Socket/DNS/TLS/连接或读取超时不归类为服务器 5xx；有 HTTP 5xx 才能归 server，429/auth/business rejection 按真实状态标注。

`PerformanceBottleneckClassifier` 是纯函数。它以真实阶段时长和类型化错误为候选：首帧/导航与慢帧为 Client UI，真实数据库搜索为 Local Database，传输不可用或类型化传输错误下的会话 sync wait 为 Network Transport，其他会话 sync wait 或已测 processing 为 Matrix Sync，lease attach 为 Matrix Room，HTTP 请求总耗时只归 Business API 请求路径（类型化错误仍可指出传输或服务端 5xx），媒体队列、下载、解码、转码分别成类，WebRTC 真实 RTT/jitter/loss 与 TURN relay 成类。单个 `/sync` 35 秒 response wait 可能是正常长轮询，缺少故障证据时不归为瓶颈；客户端 HTTP 5xx 也不能把请求总耗时冒充服务端处理耗时。两个相近且均过阈值的候选可为 `mixed`；没有真实证据返回 `unknown`。只有慢帧计数时可提示 UI 问题，但绝不把整个 Matrix 等待时间当作 UI 耗时。

阈值集中在 `PerformanceThresholds`，只影响记录/提示，不改变业务结果：会话首帧 500 ms、本地 ready 1000 ms、DB 100 ms、Business API 1000 ms、媒体首见 1000 ms、通话建立 3000 ms。Flutter 慢帧按显示刷新率计算 build/raster 预算，`frameTotal` 保留原始测量但不冒充丢帧数。正常操作默认抽样 5%，慢操作及错误保留；真机样本可重新标定阈值。

## 故障判断手册

| 情况 | 观察 | 下一步 |
| --- | --- | --- |
| A：UI 慢、网络正常 | 首帧/导航高且 build 或 raster 超预算 | 查 Flutter build、布局、图片解码与 raster；勿把 Matrix 等待算作 UI |
| B：UI 正常、sync response wait 高 | 首帧低、`sync_response_wait_ms` 高、processing 低 | 结合 transport/service/Matrix 状态查网络与 Matrix 服务器等待 |
| C：Matrix response 快、processing 慢 | response wait 低、`sync_processing_ms` 高 | 查客户端事件处理与本地数据库；具体 SQL 慢需要独立证据 |
| D：媒体排队高、加载快 | 实测 `queue_wait_ms` 高、合并加载总时长低 | 查 `MediaLoadScheduler` 的 active/queued/video active/priority；当前可作此判断 |
| E：排队低、媒体加载高 | 实测 `queue_wait_ms` 低、合并加载总时长高 | 进一步测网络、CDN/对象存储及解密；当前 SDK 没有独立 download/decrypt 边界，不能直接断言 CDN |
| F：通话 RTT/jitter/loss 高 | 有真实质量样本，`uses_turn`/relay protocol 可见 | 查 TURN relay 与跨境链路；不归因给 Matrix sync |

分位数优先看 P50/P95/P99/MAX。受维护令牌保护的 `GET /api/v1/diagnostics/performance` 返回 `RequestLatencyMetrics.snapshot()`、`DatabasePerformanceMetrics.snapshot()` 和已有媒体快照；staging/production 未配令牌时 fail closed。请求按方法、**路由模板**和状态码统计进程内滚动窗口；短期请求关联窗口只含随机操作 ID、路由模板、状态与耗时。数据库给 SQL 执行分位数、慢查询数和连接池可读计数，`connection_wait_ms=null`，因为当前 SQLAlchemy hook 不包住获取连接的等待。快照读取不新建数据库会话。所有快照是本进程/本会话窗口，不是全量历史或生产聚合平台。

## 隐私、安全与尚无数据的边界

Trace API 不接受任意 Map/string 标签。Operation、stage、错误、缓存、媒体类别、HTTP 类别、数据库操作和协议均为封闭枚举；数值字段有边界。操作 ID 为每次操作生成的随机 UUID v4，绝不由 room/user/event/txid 推导。既有视频封面短指纹使用实例内随机盐，不能跨实例长期关联。账号切换清空本地指标、待发诊断和未完成 trace。上传服务端严格拒绝额外字段，日志只收验证后的白名单。业务审计用的 `X-Trace-Id` 不接收性能 ID；进程内性能请求窗口有界且不存用户身份。消息/搜索词/姓名/电话/邮箱、用户/Matrix/房间/事件原始 ID、token、完整 URL/query、媒体 URI/路径/内容、IP、SDP/ICE candidate/TURN 凭据和 E2EE 密钥均不进入本诊断模型；相关旧调试日志已在本次触及路径脱敏。

当前 HTTP/Matrix SDK 未提供可信 DNS/TCP/TLS/TTFB 分段；媒体缓存的 `decrypt()` 回调同时覆盖下载和解密，生产路径没有独立 `download_ms`、`decrypt_ms` 或图片 `decode_ms` 标记，只能报告缓存/调度排队与合并加载总时长，不能凭这条记录独断 CDN。SDK `sendFileEvent` 合并媒体上传与事件发送，因此只能量其合并时段，不能把它拆成虚构 `upload_ms`/`send_event_ms`。封面 loader 内部是否网络命中不可直接得知，因此 `server_poster` 仅是来源，不填虚构下载/解码时长。WebRTC 没有真实首包回调时 `media_first_packet_ms` 不产生。Matrix SDK 本地库的锁等待与单条 SQL 时间当前不可读，timeline 总耗时不可当作纯 DB 时间；服务端连接池等待同样 unsupported。搜索当前主要查询本机内存索引，没有真实数据库或远程查询就不填对应阶段或历史范围。已有缓存的联系人/钱包首屏 trace 可以先完成，之后后台刷新为新操作，不把远程等待合并进首屏耗时。pending conversation 在用户停留、且后台房间仲裁尚未终结时仍是 active trace，本地已完成记录在成功或退出后出现。没有真机/弱网/跨境通话实测或生产启用证据；诊断结论需要用真实记录复核。
