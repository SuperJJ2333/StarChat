# 客户端聊天诊断通道

## 接线与边界

`ChatDiagnostics.instance` 默认未启动，`record` 为 no-op。认证会话建立后调用：

```dart
ChatDiagnostics.instance.startSession(
  version: '0.3.103+2153', // 使用当前构建元数据，不复制本示例版本
  platform: ChatDiagnosticPlatform.ios,
  upload: businessApi.uploadChatDiagnostics,
);
```

账号退出/切换/会话失效必须同步 `stopSession()`：清内存、提升 `sessionGeneration`、取消计时器并中止在途连接。跨 await 的调用方捕获 instance 与 generation，完成时同时核对，旧会话的操作不得进入新会话队列。停止不能伪装旧网络已结束：旧 flight 真正完成前不启动新 flight。

既有 `events` 只传 `ChatDiagnosticStage` / `ChatDiagnosticError` 枚举、耗时、计数与可选 HTTP 状态。操作UUID由收集器随机生成；不接受任意异常、堆栈、message/room/user ID、搜索词、正文、token、密钥或媒体。既有事件通道中普通成功操作不采集；帧预算聚合会计入正常前台帧作为分母；`slow` 小于250ms丢弃。调用方不得通过填入数字字段或UUID编码私密数据。版本仅数字 semver 加可选 `+build`，非法版本停用采集，不原样上传。

既有 `events` 同 `(stage,error,status,retry_count,lifecycle)` 聚合。内存上限100条、每批最多20条、两次启动上传至少60秒。聚合 count 封顶1,000,000，elapsed_ms封顶3,600,000；超限新类别丢弃，不持久化。错误退避1/2/4/8/15分钟并保持15分钟上限。失败本身不递归记录。高频异常只更新固定大小的字典，不触发逐条JSON序列化或IO。

`BusinessApiClient.uploadChatDiagnostics` 使用独立 `dart:io HttpClient`、既有会话内存读出的 Bearer 凭据、5秒总截止时间。停止/截止均 `close(force: true)`，不是仅 Future.timeout。该方法不调用 `_authorized` / `_decode`，401/429/失败不刷新token、不登出、不操作网络离线状态。禁止重定向，响应仅看状态，不缓存或读取任意响应正文。TLS使用系统默认验证。

## HTTP契约

`POST /api/v1/client-diagnostics`，沿用既有 TokenService 会话验证。严格JSON对象：

| 字段 | 约束 |
| --- | --- |
| version | 数字semver，可加数字build，最长32 |
| platform | android / ios / other |
| events | 可省略或0–20条；为空时必须提供 frames 或非空 operations，未知字段一律拒绝 |
| frames | 可选的前台帧预算聚合对象；未知字段一律拒绝 |
| operations | 可省略或0–20条性能操作记录；与 events 合计仍受16KB请求体限制 |
| frames.frame_count | 严格整数1–1,000,000，总采样帧数 |
| frames.slow_frame_count | build 或 raster 超出该帧刷新预算的帧数，两者同时超时只计一次 |
| frames.slow_build_count / slow_raster_count | 各阶段超预算帧数，严格整数0–1,000,000 |
| events.operation_id | 随机UUID v4（客户端内部生成） |
| events.stage | sendAdmission / matrixSend / historyLoad / historySearch / dateMonth / dateLocate / scrollAnchor / framework，以及既有刷新恢复闭合枚举（见 OpenAPI） |
| events.error | slow / network / timeout / rejected / cancelled / incomplete / unknown / recovered |
| events.elapsed_ms | 严格整数0–3,600,000 |
| events.count | 严格整数1–1,000,000 |
| events.status | null或严格整数100–599 |
| events.retry_count | 可选 null 或严格整数0–20 |
| events.lifecycle | 可选 null 或 foreground / background / unknown |

服务端逐chunk读取，累计实际字节最多16KB，不信任Content-Length；越界立即413，不读取后续chunk。认证失败401；格式失败422只返回固定错误，不回显输入/字段名称；接受202及 `{ "accepted": N }`；N为已接受的 events 数加 operations 数，frames 不计数。账户每60秒最多1批，peer IP每60秒最多30批，复用生产Redis限流，超限429。限流key中账号/IP均SHA256，不进入日志。端点不解析任意X-Forwarded-For；部署时应核实ASGI可信代理配置，以免所有客户端误计为反向代理同一IP。

仅使用 stdout 单行JSON，检索标记 `"event":"client_diagnostics"`；内容为经过验证的 version/platform/events、可选 frames 及 operations。不写业务表，不改变身份/账务/Matrix状态。错误输入、原始request及认证信息不输出。

## 帧预算聚合增量（2026-09-23，本地候选）

认证 scope 只在前台按当前 display.refreshRate 计算预算（无有效值时60Hz）。分别比较 buildDuration、rasterDuration；等于预算不计慢帧，totalSpan 只继续用于原250ms严重事件，不能换算成丢失帧数。以 `sum(slow_frame_count) / sum(frame_count)` 查看采样超预算率；它不是精确丢帧数量，也不是全设备机型分档。客户端不采集硬件型号或伪造 RAM 档位。

计数在内存中固定大小，达到一百万后丢弃整帧样本，避免分子分母不一致。成功仅减去发出快照，保留上传期间的新帧；失败保留并沿用既有退避。服务端校验 `max(build,raster) <= slow <= min(total,build+raster)`。空 events 加非空 frames 允许202；若同时没有 operations，accepted 为0。

旧服务端拒绝 frames 返回422时，客户端仅在当前会话停用该扩展，遵循现有退避，在下一允许上传时间重试原事件，不循环发送不支持的字段。换账号清除计数和兼容标记，旧 flight 不能更改新会话。后台不增加帧计数，原严重异常事件逻辑不变。帧计数是尽力而为的聚合遥测：进程终止可丢失，服务端已接收但响应丢失的重试可重复记录，不用于账务或精确活跃用户统计。发布时先服务端后客户端；尚无真机性能改善或生产启用结论。

## 日志负载与部署

代码以账户/IP/批量上限约束新流量；日志保留由部署层轮转。仓库 `infra/compose/docker-compose.wallet-manual.yml` 的 business-api 配置为 `json-file`、`max-size: 20m`、`max-file: "10"`。这不证明当前运行容器已启用该配置；生产发布前按既有跳板工作流读取实际 `HostConfig.LogConfig` 并确认相同或更严格的轮转上限，不为此覆盖整份运行compose。未配置轮转的环境不得据此宣称磁盘使用有上限。

端点自身不提供跨用户身份关联。可按版本、平台、阶段、错误类型、随机operation_id定位聚合条目；同operation_id的重试可能重复出现，统计应去重，不能把count当精确业务账目。250ms是慢操作采样门槛，不等于真机故障判定。

## 已验证范围

专项测试覆盖队列、异常风暴聚合、每分钟批量、单flight、退避、代次隔离、401/429无认证副作用、真实loopback socket取消/5秒断开、服务端认证、未知字段/污染、流式限额与限流。OpenAPI由 `scripts/export_openapi.py` 同步。证据位于 `docs/verification/artifacts/2026-09-21/chat-reliability-diagnostics/diagnostics/`。

这些不替代实际客户端接线、生产日志轮转核验、双端弱网和真机profile验证；本通道不能证明此前“对端断网导致本端红标”的根因。

## 本次运行态核验（2026-09-21）

22:33+08 诊断端已随两文件增量上线，公网 `/api/v1/health/ready` 返回200/ready，未认证诊断POST返回401。运行镜像、精确网关信任和轮转读回证据见本任务 `diagnostics/` 工件；后续发布必须重读运行态，不能继承本条作为实时证据。原始 `/health` 探针404是未匹配公开路由，已纠正为实际API健康路径。

实际应用由 `ChatDiagnosticsScope` 自动绑定认证会话；发送前检查、页面/后台发送、历史加载、搜索、日期、窗口切换及框架慢帧/异常已接线。收集器只用内存，进程杀死前未上传的批次可能丢失，不是native crash/ANR报告器。新客户端尚未打包安装，因此不能宣称线上用户已经开始上传本次诊断。

## 统一性能操作记录（2026-09-25）

`operations` 扩展既有认证与限流接口，不另建上传通道。一个对象对应一次用户操作，所有阶段共享同一随机 UUID v4 `operation_id`。服务端仅接受 [Dart 封闭模型](../../apps/mobile_flutter/lib/core/performance_trace_model.dart) 的 `PerformanceRecord.toJson()` 字段；其枚举经 camelCase 转 snake_case，例如 `conversationOpen → conversation_open`、`searchPageOpen → search_page_open`、`remoteSyncReady → remote_sync_ready`。Operation、result、stage、生命周期、网络/Matrix 状态、缓存、媒体、HTTP 类别和 TURN 协议均为 OpenAPI 列明的闭合枚举。

| 字段 | 约束 |
| --- | --- |
| operation_id | 严格 UUID v4；与同一次操作的所有阶段共用，不得从用户/房间/消息标识生成 |
| operation / result | 必填，封闭枚举 |
| total_ms | 必填，严格整数 0–3,600,000 |
| stages | 必填数组，最多64个 `{stage, elapsed_ms}`；stage 唯一，elapsed_ms 非递减且不大于 total_ms |
| lifecycle | 必填，foreground / background / resuming / unknown |
| slow_frame_count / slow_build_count / slow_raster_count | 必填，严格整数 0–1,000,000；`max(build,raster) ≤ slow ≤ build+raster` |
| soft_kick_count / hard_restart_count | 可选，严格整数 0–1,000；仅承载本次操作期间实际观察到的 Watchdog 计数增量 |
| sync_error_count / reconnect_count | 可选，严格整数 0–1,000；仅承载本次操作期间真实观察到的 Matrix sync 错误及重连计数增量 |
| last_healthy_sync_age_ms | 可选，严格整数 0–3,600,000；从已记录的最近健康 sync 时刻测得，未观测到时省略，不补零 |
| opening_source / app_network_state / matrix_state / network_error | 可选封闭枚举 |
| transport_available / service_reachable / uses_turn | 可选严格布尔值 |
| endpoint_category / method / cache_source / media_type / size_bucket / relay_protocol / candidate_protocol | 可选封闭枚举 |
| database_operation / row_count_bucket | 可选封闭枚举；仅对应真实本地数据库调用及粗粒度返回行数 |
| result_count_bucket | 可选封闭枚举；搜索结果数量桶，不等同于数据库返回行数 |
| status_code / retry_count | 可选严格整数，分别为100–599和0–20 |
| scheduler_queue / scheduler_active | 可选严格整数0–1,000 |
| rtt_ms / jitter_ms / packet_loss_percent | 可选有限数值，分别为0–60,000、0–60,000、0–100 |

`packet_loss_percent` 由客户端真实丢包/收包计数计算；服务端不接收原始 WebRTC 统计、IP、ICE candidate 或 SDP。`database_operation` 不用于本机内存索引搜索，不能把索引耗时伪称 SQL 查询。模型拒绝任意额外字段，包括原始 roomId、userId、消息、搜索词、URL/query、SQL、token、媒体路径及异常正文。错误输入只返回固定422，不回显字段值，也不写 stdout。旧客户端的 `events`/`frames` JSON 与响应保持兼容。单批最多20个 operations、20个 events，整体仍最多16KB；不能把单项上限误当为允许超过总字节上限。

服务端闭合值与当前 Dart 枚举一致：只有已实际接线的 operation 可上传；本地生成首帧视频与服务端返回的视频封面分别使用 `cache_source=local_frame` / `server_poster`，共享媒体 flight 用 `unknown` 及 `shared_flight_joined`→`shared_flight_done` 的实际等待区间，不能伪装为 scheduler queue。

接收端只负责白名单校验、限流和安全日志。何时采样或上传由客户端诊断策略决定；此扩展没有增加数据库查询，也不参与业务成功判定。日志中的分阶段耗时为客户端实测；未测得的 DNS/TCP/TLS、数据库锁等待等阶段不得补零或估算。

## 服务端只读性能快照（2026-09-25）

`GET /api/v1/diagnostics/performance` 暴露当前 Business API 进程内已有的有界聚合，不触发数据库查询、连接或客户端诊断上传。它复用 `/api/v1/media/platform/metrics` 的 `X-Media-Maintenance-Token`：配置 `media_maintenance_token` 后必须提供匹配值，否则 403；**staging 和 production 未配置时均返回 503**，防止匿名读取。development/test 未配置时仍允许读取；旧媒体维护接口维持原策略。运维应在私有网络内配置令牌，勿把令牌写入工单或性能日志。成功响应带 `Cache-Control: no-store`。

响应包含 `requests`、`database`、`media`：

| 分组 | 含义 |
| --- | --- |
| `requests[]` | 方法、已注册路由模板、状态码、样本数和耗时 `p50_ms`/`p95_ms`/`p99_ms`/`max_ms`；未匹配请求只标 `<unmatched>`。只接受框架注册的路由模板，不输出请求实际路径或 query。 |
| `recent_operation_requests[]` | 只有请求携带严格 UUID v4 `X-ChatFlow-Performance-Id` 时才写入的有界最近请求记录：`operation_id`、路由模板、状态码、真实请求总耗时。客户端关闭诊断时不发该头；无效或缺失的头不生成记录。该 ID 与审计 `X-Trace-Id` 独立，不写入 `request.state.trace_id`，两头值相同时忽略性能 ID。 |
| `database.query_latency` | 当前进程 SQL 执行阶段的样本数和 P50/P95/P99/MAX；不含连接获取、结果读取或 SQL 文本。 |
| `database.slow_query_count` | 当前进程达到数据库诊断慢查询阈值的执行次数。 |
| `database.pool` | 驱动实际支持的 size、checked_in、checked_out、overflow；不支持的值为 `null`。 |
| `database.connection_wait_ms` | 当前驱动没有可靠的 checkout 等待起止钩子，固定 `null`，表示 unsupported。 |
| `media` | 复用既有 Media Platform 的计数及 P50/P95/P99/MAX 耗时摘要。 |

`create_app` 注入 `session_factory` 而未创建 engine 的测试/嵌入场景返回 `database.supported=false`，其查询、慢查询和池字段均为 `null`；接口不为了填充指标临时连接数据库。快照仅代表当前 worker 的滚动内存窗口，不是跨 worker 或跨重启汇总。服务端不接受任何查询参数作为筛选标签，也不返回用户、房间、IP、令牌、完整 URL、SQL 或参数值。最近请求窗口只在进程内保存，不能跨账号持久关联；`operation_id` 仅用于与客户端同一次操作的诊断记录人工对照，不能作为业务或审计身份。
