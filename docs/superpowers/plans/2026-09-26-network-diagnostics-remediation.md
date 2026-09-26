# 网络稳定性与诊断修补 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking. 本轮仅交付方案，未执行以下步骤。

**Goal:** 修复网络观测缺测、卡住/重试关联和发布覆盖差异，让真实失败可以定位到具体层。

**Architecture:** 增量扩展 PerformanceTrace、PerformanceMetrics、ChatDiagnostics、既有 netmon 与 FastAPI/SQLAlchemy hooks；保留业务架构、Outbox、SDK/E2EE 和认证边界。网络、客户端与服务端为三个可独立验证的工作包；协议扩展按接收端先、客户端后交付。

**Tech Stack:** PowerShell 7、Python 3.12/标准库探针、Dart/Flutter、http/SharedPreferences、FastAPI/Pydantic/SQLAlchemy、systemd/Windows Task Scheduler。

**Status:** 用户2026-09-26批准实施及雷电 Debug 安装，执行中。依据 [设计](../specs/2026-09-26-network-diagnostics-remediation-design.md) 与 971fb50d 基线；不复做 31efd61f 已完成源码，只补缺口。正式两端发布和客户端业务节点切流不在本轮交付范围。

## 0. 工作树与证据冻结

**所有权：** 执行开始后分别声明网络脚本、客户端 core、Matrix 业务接线、服务端、交付文档的负责人；同一文件不得并发修改。app_home.dart、matrix_e2ee_client.dart 和 schema/model 由集成人顺序编辑。

- [ ] 读 AGENTS、mobile-delivery-workflow、current-state、admin-production-workflow 和本方案；检查最新 main、原脏工作树与并发任务，基于实际最新提交建立隔离工作树。
- [ ] 记录基线 commit/锁文件/tool versions、雷电包名/build、运行 API/worker digest/文件哈希、schema、两个已安装 probe/旧 netmon 哈希；历史 971fb50d/ea950a2f 不作为新的实时基线。
- [ ] 将每个下列验收 ID 建立独立证据，不重新覆盖原 67 项 WIP，不复制敏感运行配置到仓库。

## 工作包 A：网络与 NETMON

### A1 — 恢复次节点正确入口、定位雷电路径（P0；N01/N02）

**文件：** 不修改业务源码。更新 `docs/runbooks/netmon-tcp-probe.md` 与本任务记录；脱敏证据放 `docs/verification/artifacts/2026-09-26/network-diagnostics-remediation/`。

- [ ] 用已待答的 13 节点用户/端口及云控制台确认实例、IP、安全组/ACL；Console 查监听/sshd/路由，只更改实际错误项并记录前后值和回退。
- [ ] 严格 SSH 指纹与本地 TEE.pem 验证入口；未到认证只标连接/握手失败，不尝试一串用户名，也不打印私钥。
- [ ] 主服务器沿用 `scripts/starchat-server.ps1` 跳板只读路径；雷电/宿主机以 8 秒连接、12 秒总预算做同窗域名和固定 IP 对照，记录真实阶段、退出码和空阶段。
- [ ] 对照共同出口、模拟器 NAT 和服务器网关/资源；只有证据定位后修对应项。对会中 TUN/代理变动保留操作依赖，不静默影响用户网络。
- [ ] 确认次节点真实角色、业务域名/端口，再定义探测目标。没有业务角色时仅列管理入口，不能加入客户端发送节点池。

**验收：** SSH 进入认证并成功只读查询；修复项有配置前后证据。雷电结论来自同预算/同窗对照，未知原因仍列 unknown。任何节点切流需另验 TLS、身份、真实 IP 信任、Matrix/TURN 和非幂等请求，不能只凭 health200。

### A2 — 旧探针有界运行、准确失败与缺测（P0；N03）

**修改：** `scripts/netmon_tcp_probe.py`、`tests/infra/test_netmon_tcp_probe.py`、`docs/runbooks/netmon-tcp-probe.md`。

**远端受控增量：** `/opt/starchat/netmon-sg.sh`、`/etc/systemd/system/netmon-sg.service`；timer 保持分钟频率。已有443任务不更改。

- [ ] 增加红测：次目标 allowlist、3 秒真实截止、拒绝/超时后 connect=null、探针故障独立、旧 origin_tcp443 参数兼容、分钟缺测与失败不同分母、日志/状态容量。
- [ ] 运行 `py -3.12 -m pytest tests/infra/test_netmon_tcp_probe.py -q`，保存预期红测输出。
- [ ] 复用标准库 connect/monotonic clock，实现固定类别目标与每分钟一次管理入口测量；旧脚本调用新探针，service `TimeoutStartSec=8`，失败结果和执行故障分别编码。
- [ ] 运行同一专项转绿；源站 Linux 校验 unit、Windows task 参数兼容、实际无重叠。冻结原三文件 SHA/权限/启用状态，按清单备份再安装；不覆盖发生漂移的对象。
- [ ] 验证两个不同分钟的真实调度、断开目标时有限返回与日志轮转，保留原日志；记录安全回退命令和前后哈希。
- [ ] 独立提交网络修补，不夹带 API/客户端行为变动。

### A3 — 区域观测（P1；N04）

**扩展：** 上述探针/runbook；如新增 HTTPS 探针模块，归入现有 netmon 调度及同一容量/目标 allowlist，测试放 `tests/infra/test_netmon_tcp_probe.py` 的邻近专用文件，不引入新平台。

- [ ] 每个用户出口单独测 DNS、TCP443、TLS 合法 SNI、公开 Business ready 与 Matrix versions；SSH管理端口另列。每分钟3尝试，connect3秒；HTTPS每轮总截止不超过30秒，无重叠。
- [ ] 对固定 IP 与域名请求分别统计，不把 curl 的分段时间混入 APP trace。所有后续未完成阶段 null，采集质量有独立计数。
- [ ] 先大陆电信/联通/移动真实出口，现有 ECS 加作观察点；按实际用户增加香港/东南亚。记录已覆盖和缺失组合，运行24小时含晚高峰，再7天。
- [ ] 给出各阶段失败率、连续失败、采集缺测、成功样本 P50/P95/P99/MAX 及样本数。连续3轮失败或TCP P95>1000ms是集中配置的初始排查阈值，不用于业务控制。

## 工作包 B：客户端关联与测量

### B1 — 同根多记录与本地恢复/ACK（P0；C01）

**修改：** `apps/mobile_flutter/lib/core/chat_diagnostics.dart`、`apps/mobile_flutter/lib/core/chat_diagnostics_spool_store.dart`；测试 `apps/mobile_flutter/test/core/chat_diagnostics_spool_test.dart`、`apps/mobile_flutter/test/core/chat_diagnostics_test.dart`、`apps/mobile_flutter/test/performance/performance_trace_upload_test.dart`。禁止另写一个 spool 系统。

- [ ] 红测固定输入：一个 wallet 根记录与两个不同 apiRequest 共享 operationId，暂存恢复后3条均在；上传期间加同根第4条，202只能扣发出的3条；旧v2同根记录迁移不丢；401和账号切换不误ACK。
- [ ] 运行下面客户端专项命令并保存失败原因。
- [ ] 在现有队列增加私有 queue_entry_id，spool v3只接受严格UUID与现有闭集 payload；wire operation_id 保持根ID。restore/ACK匹配不可变条目身份，不按根ID去重；延续100条/64KiB/24h与串行I/O。
- [ ] 同命令转绿，测试超大/过期/损坏/v2兼容/旧账号晚到结果；规格评审后质量与隐私评审，再提交。

### B2 — 在途 snapshot 与观察期限（P0；C02）

**修改：** `apps/mobile_flutter/lib/core/performance_trace.dart`、`performance_trace_model.dart`、`performance_metrics.dart`；测试 `test/performance/performance_trace_test.dart`、`performance_metrics_test.dart`、`performance_trace_upload_test.dart`。

- [ ] 红测100并发无串线、卡住阶段可读、45秒/5分钟观察释放槽位、dispose不抹掉已产生的安全观察、finish幂等、业务Future未被取消，后续完成沿同根ID。
- [ ] 实现有界 active snapshot、一个 recorder 观察任务、集中期限和typed过期观察。root correlation context仅由既有job生命周期持有，带内部UUID/recorder/账号代次/释放状态；active span过期不使根ID丢失，账号切换同步失效。mark仍只读时钟/改内存，快照编码和排序走显式低频读取。
- [ ] 延迟帧回调/未启用帧的数据保持 attribution incomplete，不补0；超期/在途不计入完成分位数。
- [ ] P0先验收本地VM在途视图。P1远程checkpoint/expired上报以 `observation_kind` 和 `observed_elapsed_ms` 的明确闭集契约区分完成结果，只在D1兼容后开启。新扩展独立能力/批次边界，旧端422只停用不支持的扩展并保留已支持操作，不能整批清空基线记录或高频重发。专项转绿并提交。

### B3 — 会话、视频重试、Outbox 与 Matrix（P0；C03）

**修改：** `apps/mobile_flutter/lib/app_home.dart`、`features/matrix/room_page.dart`、`room_timeline_controller.dart`、`matrix_e2ee_client.dart`、`matrix_outgoing_work_coordinator.dart`、`matrix_sync_phase_metrics.dart`、`core/outbox/message_send_scheduler.dart`；以上简写均相对 `apps/mobile_flutter/lib/`，共享context/枚举由 B2负责人顺序修改。

**测试：** `test/features/matrix/room_open_performance_trace_test.dart`、`video_transcode_performance_trace_test.dart`、`matrix_outgoing_work_coordinator_test.dart`、`outbox_send_flow_test.dart`、`test/core/outbox/message_send_scheduler_test.dart`，新增 `test/features/matrix/video_retry_performance_trace_test.dart`；测试简写均相对 `apps/mobile_flutter/`。

- [ ] 红测列表/搜索/通知第一次await前计入T0；前置失败也有记录，好友现有路径不回归。
- [ ] 红测视频首次失败→等待网络→第二次成功，共根ID、retry_count真实、每次实际执行新建attempt span未被finished对象吞掉；prepare只执行一次时不造第二次转码，echo先于HTTP失败仍沿业务结果sent。后台/临时lease文本同样能关联persist/admission/SDK/ACK；媒体队列无真实persist时缺省该阶段。
- [ ] 红测投影publish不能标真实绘制；首帧 callback 才标绘制，有滚动不可见时保持未观测。
- [ ] 红测35秒正常sync response不被误判；失败sync带真实错误与Watchdog本轮增量，resume指标不冒称已刷新所有消息。
- [ ] 实现公共trace参数传递、typed尝试与阶段回调，仅观测、不改业务重试/发送顺序/SDK fork/E2EE；跑对应专项转绿并提交。

### B4 — 错误分类与慢帧采样（P0；C04）

**修改：** `core/business_api_performance_client.dart`、`business_api_client.dart`、`performance_trace_model.dart`、`chat_diagnostics.dart`、`features/matrix/video_poster_extractor.dart`（均在 `apps/mobile_flutter/lib/`）；测试 `test/core/business_api_performance_test.dart`、`business_api_diagnostics_test.dart`、`test/performance/performance_frame_attribution_test.dart`、`test/features/matrix/call_diagnostics_logging_test.dart`，新增 `test/features/matrix/video_poster_logging_privacy_test.dart`。

- [ ] 红测generic Timeout→request_timeout且phase未知；401→auth_failure而非offline，401后实际重放200时逻辑结果success+retry1；429/5xx/TLS/socket保持准确分类；aggregate event UUID不冒称根操作。
- [ ] 红测操作时长正常但真实slow_frames达到阈值也必留；未测帧不能因此强留或归因UI。
- [ ] 原生poster日志只能输出fixed code/tag，不输出error字符串/文件路径；未知异常为unknown。
- [ ] 实现最小类型化映射/采样及日志脱敏，保留授权会话/上传独立超时、generation与退避；不改变认证状态或业务超时。专项转绿并提交。

### B5 — DB、媒体、页面与通话精度（P1；C05）

**修改：** `features/matrix/media_cache.dart`、`content_addressed_media.dart`、`prepared_chat_video.dart`、`video_poster_pipeline.dart`、`call_controller.dart`、`matrix_call_adapter.dart`、`call_quality_monitor.dart`、`features/search/global_search_page.dart`、`global_search_controller.dart`，及真正DB调用所在的既有文件；不为获取指标重写数据库/Matrix fork。

**测试：** `test/performance/media_cache_metrics_test.dart`、`test/features/matrix/video_poster_performance_trace_test.dart`、`call_quality_monitor_performance_test.dart`、`call_setup_performance_trace_test.dart`、`test/features/search/global_search_controller_test.dart`、`test/performance/performance_timing_summary_pages_test.dart`。

- [ ] 建立红测：queue1800ms/download100ms的已知实测组合判客户端调度；合并SDK耗时只输出combined、没有分界则null；poster子请求同根。
- [ ] 红测独立实际DB调用+行数桶，整体timeline恢复不填DB；每次搜索提交均有新操作，不记录query。
- [ ] 红测call窗口先恶化后恢复仍保留尖峰、包计数reset不生成猜测loss、relay切换与同一次样本RTT配对，窗口max与代表样本分列，setup/active/reconnect同根；remoteTrack不冒充firstPacket。
- [ ] 利用已有真实事件/回调实现可测部分，30秒有界窗口最多6样本且复用5秒getStats、不增调用；stop补最后非空窗口，空窗口不报正常。真实不可测项目列unsupported；专项转绿并提交。

### B6 — 语义摘要、分类与采样口径（P1；C06）

**修改：** `core/performance_metrics.dart`、`performance_trace_model.dart`、`chat_diagnostics.dart`；测试 `test/performance/performance_bottleneck_classifier_test.dart`、`performance_metrics_test.dart`、`performance_timing_summary_pages_test.dart`。

- [ ] 红测 operation+指定起止区间分桶，不同页面不混首帧；incomplete不进完成样本；unknown/mixed和正常Matrix长轮询正确。
- [ ] 扩展现有有界摘要，输出样本数、窗口和P50/P95/P99/MAX。record不排序，snapshot低频计算；客户端采样上传标明偏采样，不能称全体用户分位数。
- [ ] 若Release需要总体分布，扩展原ChatDiagnostics固定bucket完整分母摘要；每桶由真正全量元数据更新、固定上限、兼容先D1，输出桶近似范围，不能声称精确P99。
- [ ] 复用纯classifier输出实测证据；专项转绿后提交，更新诊断手册和隐私审查。

## 工作包 D：服务端与交付

### D1 — 严格协议与现有服务端 hooks（P0；S01/S02）

**修改：** `services/business-api/app/api/client_diagnostics.py`、`api/performance_diagnostics.py`、`core/tracing.py`、`core/database.py`、`main.py`；仅新增字段/枚举需要改接收端，已有hooks首先复用，不机械重写。

**测试：** `tests/business_api/test_client_diagnostics.py`、`test_performance_snapshot_api.py`、`test_tracing_metrics.py`、`test_database.py`；通过 `scripts/export_openapi.py` 更新 `packages/api-contracts/openapi/liuhetong-v1.yaml`。

- [ ] 红测新增request_timeout、observation_kind、observed_elapsed_ms、attempt_index/window_index等已实际使用字段闭集及数值上限；新观察有独立完整/部分语义，旧完成记录默认final。旧协议通过，任意ID/消息/token/URL/SDP污染拒绝且不回显；旧端拒绝扩展不吞基线队列。
- [ ] 红测维护快照production无配置503、错误令牌403、正确令牌no-store；读取不连接DB、不返回实际URL或SQL参数；请求异常也有记录。
- [ ] 将当前main的 middleware/SQL hooks/router接线纳入候选。若补请求↔DB关联，以现有请求上下文和实际Session边界测量，测试并发/线程/后台作用域隔离；无可靠connection-wait钩子保持null。
- [ ] 对真实外部依赖边界记录固定类别与耗时，未有边界的依赖保持unsupported；不增加监控专用业务查询。
- [ ] 跑下方后端专项，转绿后完成规格与质量/安全评审。发布从当时运行镜像增量制作，记录全文件manifest/SHA、令牌配置与差异，不整体覆盖Compose/环境。
- [ ] 按admin-production/refresh-release-guards完成候选及回退协议、数据库备份恢复等现有发布要求；API-only健康切换，worker/schema/其他容器不变。运行时查文件hash、真实安全接口与同根测试请求，不能仅看接收202。

### D2 — 新Debug与正式交付一致（P0；R01）

**文件：** `apps/mobile_flutter/pubspec.yaml` 与确实需要变更的构建元数据；`tests/mobile/test_app_build_contract.py`；更新 `docs/runbooks/client-diagnostics.md`、`docs/performance/chatflow-performance-diagnostics.md`、本任务记录及新的验包报告。

- [ ] 预检线上/CI/并发任务占用build，冻结下一个可用四位数字，不能凭2179直接认定2180可用；保留已有build归一化修复。
- [ ] 明确APK source commit与包含能力；Debug使用现有PerformanceMetrics define，正常Release继续profile-only帧与认证后低频ChatDiagnostics。
- [ ] 按android-apk-rebuild做source→常规DEX/资源/Manifest重建→zipalign→固定用户测试签名→最终包验证。检查包名、四位build、签名、ABI/资产与SHA。
- [ ] 雷电online且旧包/数据状态确认后覆盖安装，不卸载/清数据；验证VM实读四位build、新暂存/失败分类和在途快照。真实发送使用授权测试账号/无敏感测试素材，不能操作用户短信或重复非幂等发送。
- [ ] 分别实测聊天入口、文字、短视频成功/失败重试、弱网恢复补报、前后台恢复；以同根记录定位真实阶段，保持E2EE/旧数据。需要用户完成的账号动作只阻断对应验收。
- [ ] 对照关闭/启用诊断的CPU/内存/帧数据，记录测量窗口与profile条件；Debug时长不当作Release性能结论。
- [ ] Android/iOS正式包各自构建/签名/真机与分发验收；未构建的一端明确为未交付，不把源码已合并当作正式用户已获得修补。

## 门禁命令与预期结果

每次PowerShell7会话先设置UTF-8无BOM和PYTHONUTF8/PYTHONIOENCODING；在指定工作目录运行，结果必须记录真实退出码/数量/skip。以下是**未来命令，不是本轮通过证据**。

```powershell
# 仓库根：网络专项
py -3.12 -m pytest tests/infra/test_netmon_tcp_probe.py -q

# apps/mobile_flutter：核心关联专项
& C:/src/flutter/bin/flutter.bat test test/core/chat_diagnostics_test.dart test/core/chat_diagnostics_spool_test.dart test/core/business_api_performance_test.dart test/core/business_api_diagnostics_test.dart test/performance

# apps/mobile_flutter：必需Flutter门禁
& C:/src/flutter/bin/flutter.bat analyze lib test
& C:/src/flutter/bin/flutter.bat test test/features/matrix
& C:/src/flutter/bin/flutter.bat test

# 仓库根：后端专项
$env:PYTHONPATH='services/business-api;services/business-worker/app;.'
py -3.12 -m pytest tests/business_api/test_client_diagnostics.py tests/business_api/test_performance_snapshot_api.py tests/business_api/test_tracing_metrics.py tests/business_api/test_database.py -q

# 仓库根：后端全量与统一门禁，先预检环境
py -3.12 -m pytest tests/business_api tests/business_worker -q
pwsh.exe -NoProfile -File scripts/verify.ps1
```

预期：analyze `No issues found`，适用测试 exit0；异常/skip原因有记录。verify缺环境时记录真实失败和适用分项，不复制生产secret凑门禁；按mobile工作流只复用未变输入的证据。

## 最终验收映射

| ID | 验收证据 |
| --- | --- |
| N01/N02 | 次入口真实恢复；雷电同窗路径对照与按证据修配置 |
| N03/N04 | 探针有界、失败/缺测不同分母、两分钟实证、24h及7天区域报告 |
| C01/C02 | 同根多记录不丢、ACK只扣快照、100并发、挂住/观察超期仍有证据 |
| C03/C04 | 会话所有入口、视频重试/Outbox、网络错误真实分类、慢帧必留 |
| C05/C06 | DB/媒体真实边界、通话尖峰、语义分位数与偏采样标注 |
| S01/S02 | 严格旧新协议、受保护快照、运行镜像request/SQL接线实证 |
| R01 | 四位build固定签名最终包、雷电保留数据安装及真实操作链；正式两端状态分别记录 |

所有日志与字段闭合；没有消息、身份、token、原始room/event/txid、路径、媒体、SQL、SDP、ICE或E2EE数据。尚无真实边界的数据保持unsupported。风险与回退见设计第7节。
