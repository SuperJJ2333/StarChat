# 网络稳定性与诊断修补 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking. 本轮已实施并交付雷电 Debug；下列勾选只表示该项已有实际证据，未勾选项注明部分完成或外部限制。

**Goal:** 修复网络观测缺测、卡住/重试关联和发布覆盖差异，让真实失败可以定位到具体层。

**Architecture:** 增量扩展 PerformanceTrace、PerformanceMetrics、ChatDiagnostics、既有 netmon 与 FastAPI/SQLAlchemy hooks；保留业务架构、Outbox、SDK/E2EE 和认证边界。网络、客户端与服务端为三个可独立验证的工作包；协议扩展按接收端先、客户端后交付。

**Tech Stack:** PowerShell 7、Python 3.12/标准库探针、Dart/Flutter、http/SharedPreferences、FastAPI/Pydantic/SQLAlchemy、systemd/Windows Task Scheduler。

**Status:** 用户2026-09-26批准实施及雷电 Debug 安装。源码修补、完整 Flutter 门禁、NETMON 两点安装与 API-only 发布已完成；`0.4.13 / Build 2180` 于19:29香港时间保留数据覆盖安装雷电，21:40:21香港时间 VM 实读 build2180、metrics enabled 和既有诊断扩展成功。APK 对应源码 `b74cefc8b98e326cef1871c1ddeb500e22d8f22b`。真实快照记录friendship API 5007ms / TLS failure；21:45新窗口还捕获会话打开729ms、message_send成功2102ms（SDK阶段1707ms、7个慢build帧）及一次sync processing6750ms。具体网络与处理长尾根因仍在调查，不能称业务链路已全部恢复。依据 [设计](../specs/2026-09-26-network-diagnostics-remediation-design.md) 与971fb50d基线；不复做31efd61f已完成源码。正式两端发布和客户端业务节点切流不在本轮交付范围。实际数量、失败与限制以[交付验收](../../verification/2026-09-26-network-diagnostics-remediation.md)和[任务记录](../../workflow/tasks/2026-09-26-network-diagnostics-remediation.md)为准。

## 0. 工作树与证据冻结

**所有权：** 执行开始后分别声明网络脚本、客户端 core、Matrix 业务接线、服务端、交付文档的负责人；同一文件不得并发修改。app_home.dart、matrix_e2ee_client.dart 和 schema/model 由集成人顺序编辑。

- [x] 读 AGENTS、mobile-delivery-workflow、current-state、admin-production-workflow 和本方案；检查最新 main、原脏工作树与并发任务，基于实际最新提交建立隔离工作树。
- [x] 记录基线 commit/锁文件/tool versions、雷电包名/build、运行 API/worker digest/文件哈希、schema、两个已安装 probe/旧 netmon 哈希；历史 971fb50d/ea950a2f 不作为新的实时基线。
- [x] 将每个下列验收 ID 建立独立证据，不重新覆盖原 67 项 WIP，不复制敏感运行配置到仓库。

## 工作包 A：网络与 NETMON

### A1 — 恢复次节点正确入口、定位雷电路径（P0；N01/N02）

**文件：** 不修改业务源码。更新 `docs/runbooks/netmon-tcp-probe.md` 与本任务记录；脱敏证据放 `docs/verification/artifacts/2026-09-26/network-diagnostics-remediation/`。

- [ ] 用已待答的 13 节点用户/端口及云控制台确认实例、IP、安全组/ACL；Console 查监听/sshd/路由，只更改实际错误项并记录前后值和回退。 **状态：未完成：缺真实入口及云控制台权限，尚未更改该节点配置。**
- [ ] 严格 SSH 指纹与本地 TEE.pem 验证入口；未到认证只标连接/握手失败，不尝试一串用户名，也不打印私钥。 **状态：部分完成：18:09:35香港时间一次受限入口核对仍为认证前 banner timeout；未读取或打印私钥，密钥有效性保持 unknown。**
- [x] 主服务器沿用 `scripts/starchat-server.ps1` 跳板只读路径；雷电/宿主机以 8 秒连接、12 秒总预算做同窗域名和固定 IP 对照，记录真实阶段、退出码和空阶段。
- [ ] 对照共同出口、模拟器 NAT 和服务器网关/资源；只有证据定位后修对应项。对会中 TUN/代理变动保留操作依赖，不静默影响用户网络。 **状态：部分完成：已取得宿主机/雷电同窗对照及主服务器资源证据；19:41雷电公开HTTPS成功而宿主机TLS失败，21:41两端均4/4 TLS失败、TCP已完成，同时源站ready200/healthy。Meta TUN共同出口是调查线索，尚未确认具体NAT、TUN或网关根因，未静默改网络配置。**
- [ ] 确认次节点真实角色、业务域名/端口，再定义探测目标。没有业务角色时仅列管理入口，不能加入客户端发送节点池。 **状态：未完成：管理入口与业务角色均待确认，该IP未加入客户端发送节点池。**

**验收：** SSH 进入认证并成功只读查询；修复项有配置前后证据。雷电结论来自同预算/同窗对照，未知原因仍列 unknown。任何节点切流需另验 TLS、身份、真实 IP 信任、Matrix/TURN 和非幂等请求，不能只凭 health200。

### A2 — 旧探针有界运行、准确失败与缺测（P0；N03）

**修改：** `scripts/netmon_tcp_probe.py`、`tests/infra/test_netmon_tcp_probe.py`、`docs/runbooks/netmon-tcp-probe.md`。

**远端受控增量：** `/opt/starchat/netmon-sg.sh`、`/etc/systemd/system/netmon-sg.service`；timer 保持分钟频率。已有443任务不更改。

- [x] 增加红测：次目标 allowlist、3 秒真实截止、拒绝/超时后 connect=null、探针故障独立、旧 origin_tcp443 参数兼容、分钟缺测与失败不同分母、日志/状态容量。
- [x] 运行TCP/HTTPS联合专项 `py -3.12 -m pytest tests/infra/test_netmon_tcp_probe.py tests/infra/test_netmon_https_probe.py -q`，保存实际RED15失败/29通过和最终GREEN52通过exit0。
- [x] 复用标准库 connect/monotonic clock，实现固定类别目标与每分钟一次管理入口测量；旧脚本调用新探针，service `TimeoutStartSec=8`，失败结果和执行故障分别编码。
- [x] 运行同一专项转绿；源站 Linux 校验 unit、Windows task 参数兼容、实际无重叠。冻结原三文件 SHA/权限/启用状态，按清单备份再安装；不覆盖发生漂移的对象。
- [x] 验证两个不同分钟的真实调度、不可达目标时有限返回与日志轮转，保留原日志；记录安全回退命令和前后哈希。实际使用现有13节点超时验证有界返回；日志容量/轮转由专项验证，未为验收中断生产节点或执行live rollback。
- [x] 独立提交网络修补，不夹带 API/客户端行为变动。

### A3 — 区域观测（P1；N04）

**扩展：** 上述探针/runbook；如新增 HTTPS 探针模块，归入现有 netmon 调度及同一容量/目标 allowlist，测试放 `tests/infra/test_netmon_tcp_probe.py` 的邻近专用文件，不引入新平台。

- [ ] 每个用户出口单独测 DNS、TCP443、TLS 合法 SNI、公开 Business ready 与 Matrix versions；SSH管理端口另列。每分钟3尝试，connect3秒；HTTPS每轮总截止不超过30秒，无重叠。 **状态：部分完成：源站Linux与大陆阿里云ECS已安装四组分钟HTTPS探针，严格TLS/SNI、3次/组和30秒总预算通过；这些观察点不代表全部用户出口。**
- [x] 对固定 IP 与域名请求分别统计，不把 curl 的分段时间混入 APP trace。所有后续未完成阶段 null，采集质量有独立计数。
- [ ] 先大陆电信/联通/移动真实出口，现有 ECS 加作观察点；按实际用户增加香港/东南亚。记录已覆盖和缺失组合，运行24小时含晚高峰，再7天。 **状态：未完成：现有ECS单点不能替代三运营商、香港/东南亚真实出口；24小时晚高峰和7天数据尚未取得。**
- [x] 实现各阶段失败率、连续失败、采集缺测、成功样本 P50/P95/P99/MAX 及样本数的有界统计；现有短窗有实际结果，尚无24h/7d报告。连续3轮失败或TCP P95>1000ms是集中配置的初始排查阈值，不用于业务控制。

## 工作包 B：客户端关联与测量

### B1 — 同根多记录与本地恢复/ACK（P0；C01）

**修改：** `apps/mobile_flutter/lib/core/chat_diagnostics.dart`、`apps/mobile_flutter/lib/core/chat_diagnostics_spool_store.dart`；测试 `apps/mobile_flutter/test/core/chat_diagnostics_spool_test.dart`、`apps/mobile_flutter/test/core/chat_diagnostics_test.dart`、`apps/mobile_flutter/test/performance/performance_trace_upload_test.dart`。禁止另写一个 spool 系统。

- [x] 红测固定输入：一个 wallet 根记录与两个不同 apiRequest 共享 operationId，暂存恢复后3条均在；上传期间加同根第4条，202只能扣发出的3条；旧v2同根记录迁移不丢；401和账号切换不误ACK。
- [x] 运行下面客户端专项命令并保存失败原因。
- [x] 在现有队列增加私有 queue_entry_id，spool v3只接受严格UUID与现有闭集 payload；wire operation_id 保持根ID。restore/ACK匹配不可变条目身份，不按根ID去重；延续100条/64KiB/24h与串行I/O。
- [x] 同命令转绿，测试超大/过期/损坏/v2兼容/旧账号晚到结果；规格评审后质量与隐私评审，再提交。

### B2 — 在途 snapshot 与观察期限（P0；C02）

**修改：** `apps/mobile_flutter/lib/core/performance_trace.dart`、`performance_trace_model.dart`、`performance_metrics.dart`；测试 `test/performance/performance_trace_test.dart`、`performance_metrics_test.dart`、`performance_trace_upload_test.dart`。

- [x] 红测100并发无串线、卡住阶段可读、45秒/5分钟观察释放槽位、dispose不抹掉已产生的安全观察、finish幂等、业务Future未被取消，后续完成沿同根ID。
- [x] 实现有界 active snapshot、一个 recorder 观察任务、集中期限和typed过期观察。root correlation context仅由既有job生命周期持有，带内部UUID/recorder/账号代次/释放状态；active span过期不使根ID丢失，账号切换同步失效。mark仍只读时钟/改内存，快照编码和排序走显式低频读取。
- [x] 延迟帧回调/未启用帧的数据保持 attribution incomplete，不补0；超期/在途不计入完成分位数。
- [x] P0先验收本地VM在途视图。P1远程checkpoint/expired上报以 `observation_kind` 和 `observed_elapsed_ms` 的明确闭集契约区分完成结果，只在D1兼容后开启。新扩展独立能力/批次边界，旧端422只停用不支持的扩展并保留已支持操作，不能整批清空基线记录或高频重发。专项转绿并提交。

### B3 — 会话、视频重试、Outbox 与 Matrix（P0；C03）

**修改：** `apps/mobile_flutter/lib/app_home.dart`、`features/matrix/room_page.dart`、`room_timeline_controller.dart`、`matrix_e2ee_client.dart`、`matrix_outgoing_work_coordinator.dart`、`matrix_sync_phase_metrics.dart`、`core/outbox/message_send_scheduler.dart`；以上简写均相对 `apps/mobile_flutter/lib/`，共享context/枚举由 B2负责人顺序修改。

**测试：** `test/features/matrix/room_open_performance_trace_test.dart`、`video_transcode_performance_trace_test.dart`、`matrix_outgoing_work_coordinator_test.dart`、`outbox_send_flow_test.dart`、`test/core/outbox/message_send_scheduler_test.dart`，新增 `test/features/matrix/video_retry_performance_trace_test.dart`；测试简写均相对 `apps/mobile_flutter/`。

- [x] 红测列表/搜索/通知第一次await前计入T0；前置失败也有记录，好友现有路径不回归。
- [x] 红测视频首次失败→等待网络→第二次成功，共根ID、retry_count真实、每次实际执行新建attempt span未被finished对象吞掉；prepare只执行一次时不造第二次转码，echo先于HTTP失败仍沿业务结果sent。后台/临时lease文本同样能关联persist/admission/SDK/ACK；媒体队列无真实persist时缺省该阶段。
- [ ] 红测投影publish不能标真实绘制；首帧 callback 才标绘制，有滚动不可见时保持未观测。 **状态：部分完成：已将实际模型发布命名 timelinePublished，缺真实绘制证据时不生成 send_to_visible；消息级 keyed rendered-frame hook 尚未接入，保持 unsupported。**
- [x] 红测35秒正常sync response不被误判；失败sync带真实错误与Watchdog本轮增量，resume指标不冒称已刷新所有消息。
- [x] 实现公共trace参数传递、typed尝试与阶段回调，仅观测、不改业务重试/发送顺序/SDK fork/E2EE；跑对应专项转绿并提交。

### B4 — 错误分类与慢帧采样（P0；C04）

**修改：** `core/business_api_performance_client.dart`、`business_api_client.dart`、`performance_trace_model.dart`、`chat_diagnostics.dart`、`features/matrix/video_poster_extractor.dart`（均在 `apps/mobile_flutter/lib/`）；测试 `test/core/business_api_performance_test.dart`、`business_api_diagnostics_test.dart`、`test/performance/performance_frame_attribution_test.dart`、`test/features/matrix/call_diagnostics_logging_test.dart`，新增 `test/features/matrix/video_poster_logging_privacy_test.dart`。

- [x] 红测generic Timeout→request_timeout且phase未知；401→auth_failure而非offline，401后实际重放200时逻辑结果success+retry1；429/5xx/TLS/socket保持准确分类；aggregate event UUID不冒称根操作。
- [x] 红测操作时长正常但真实slow_frames达到阈值也必留；未测帧不能因此强留或归因UI。
- [x] 原生poster日志只能输出fixed code/tag，不输出error字符串/文件路径；未知异常为unknown。
- [x] 实现最小类型化映射/采样及日志脱敏，保留授权会话/上传独立超时、generation与退避；不改变认证状态或业务超时。专项转绿并提交。

### B5 — DB、媒体、页面与通话精度（P1；C05）

**修改：** `features/matrix/media_cache.dart`、`content_addressed_media.dart`、`prepared_chat_video.dart`、`video_poster_pipeline.dart`、`call_controller.dart`、`matrix_call_adapter.dart`、`call_quality_monitor.dart`、`features/search/global_search_page.dart`、`global_search_controller.dart`，及真正DB调用所在的既有文件；不为获取指标重写数据库/Matrix fork。

**测试：** `test/performance/media_cache_metrics_test.dart`、`test/features/matrix/video_poster_performance_trace_test.dart`、`call_quality_monitor_performance_test.dart`、`call_setup_performance_trace_test.dart`、`test/features/search/global_search_controller_test.dart`、`test/performance/performance_timing_summary_pages_test.dart`。

- [ ] 建立红测：queue1800ms/download100ms的已知实测组合判客户端调度；合并SDK耗时只输出combined、没有分界则null；poster子请求同根。 **状态：部分完成：队列/网络分类沿用真实区间，SDK只报告可测combined阶段；SDK内部poster/thumbnail子请求未有公共typed上下文接口，不能保证与父媒体请求同根。**
- [x] 红测独立实际DB调用+行数桶，整体timeline恢复不填DB；每次搜索提交均有新操作，不记录query。
- [ ] 红测call窗口先恶化后恢复仍保留尖峰、包计数reset不生成猜测loss、relay切换与同一次样本RTT配对，窗口max与代表样本分列，setup/active/reconnect同根；remoteTrack不冒充firstPacket。 **状态：部分完成：尖峰与同一样本TURN/RTT配对、setup/active同根及空窗口测试通过；包丢失率只用真实累计计数对，不猜窗口增量，独立call_reconnect链和WebRTC真实firstPacket仍 unsupported。**
- [x] 利用已有真实事件/回调实现可测部分，复用5秒getStats、不增调用并防止poll重叠；单调时钟至少30秒后首个有效poll结算，以O(1)代表样本保留尖峰，既有全通话样本上限128。stop补最后非空窗口，空窗口不报正常。真实不可测项目列unsupported；专项转绿并提交。没有把窗口声称为恰好30秒或固定6个成功样本。

### B6 — 语义摘要、分类与采样口径（P1；C06）

**修改：** `core/performance_metrics.dart`、`performance_trace_model.dart`、`chat_diagnostics.dart`；测试 `test/performance/performance_bottleneck_classifier_test.dart`、`performance_metrics_test.dart`、`performance_timing_summary_pages_test.dart`。

- [x] 红测 operation+指定起止区间分桶，不同页面不混首帧；incomplete不进完成样本；unknown/mixed和正常Matrix长轮询正确。
- [x] 扩展现有有界摘要，输出样本数、窗口和P50/P95/P99/MAX。record不排序，snapshot低频计算；客户端采样上传标明偏采样，不能称全体用户分位数。
- [ ] 若Release需要总体分布，扩展原ChatDiagnostics固定bucket完整分母摘要；每桶由真正全量元数据更新、固定上限、兼容先D1，输出桶近似范围，不能声称精确P99。 **状态：本轮未实现总体分母上传分布；本地完整窗口摘要与慢/错误偏采样上传分别标注，不将上传样本P99冒称全体用户P99。**
- [x] 复用纯classifier输出实测证据；专项转绿后提交，更新诊断手册和隐私审查。

## 工作包 D：服务端与交付

### D1 — 严格协议与现有服务端 hooks（P0；S01/S02）

**修改：** `services/business-api/app/api/client_diagnostics.py`、`api/performance_diagnostics.py`、`core/tracing.py`、`core/database.py`、`main.py`；仅新增字段/枚举需要改接收端，已有hooks首先复用，不机械重写。

**测试：** `tests/business_api/test_client_diagnostics.py`、`test_performance_snapshot_api.py`、`test_tracing_metrics.py`、`test_database.py`；通过 `scripts/export_openapi.py` 更新 `packages/api-contracts/openapi/liuhetong-v1.yaml`。

- [x] 红测新增request_timeout、observation_kind、observed_elapsed_ms、attempt_index/window_index等已实际使用字段闭集及数值上限；新观察有独立完整/部分语义，旧完成记录默认final。旧协议通过，任意ID/消息/token/URL/SDP污染拒绝且不回显；旧端拒绝扩展不吞基线队列。
- [x] 红测维护快照production无配置503、错误令牌403、正确令牌no-store；读取不连接DB、不返回实际URL或SQL参数；请求异常也有记录。
- [x] 将当前main的 middleware/SQL hooks/router接线纳入候选。若补请求↔DB关联，以现有请求上下文和实际Session边界测量，测试并发/线程/后台作用域隔离；无可靠connection-wait钩子保持null。
- [x] 对真实外部依赖边界记录固定类别与耗时，未有边界的依赖保持unsupported；不增加监控专用业务查询。
- [x] 跑下方后端专项，转绿后完成规格与质量/安全评审。发布从当时运行镜像增量制作，记录全文件manifest/SHA、令牌配置与差异，不整体覆盖Compose/环境。
- [x] 按admin-production/refresh-release-guards完成候选及回退协议、数据库备份恢复等现有发布要求；API-only健康切换，worker/schema/其他容器不变。运行时查文件hash、真实安全接口与同根测试请求，不能仅看接收202。

### D2 — 新Debug与正式交付一致（P0；R01）

**文件：** `apps/mobile_flutter/pubspec.yaml` 与确实需要变更的构建元数据；`tests/mobile/test_app_build_contract.py`；更新 `docs/runbooks/client-diagnostics.md`、`docs/performance/chatflow-performance-diagnostics.md`、本任务记录及新的验包报告。

- [x] 预检线上/CI/并发任务占用build，冻结下一个可用四位数字，不能凭2179直接认定2180可用；保留已有build归一化修复。
- [x] 明确APK source commit与包含能力；Debug使用现有PerformanceMetrics define，正常Release继续profile-only帧与认证后低频ChatDiagnostics。
- [x] 按android-apk-rebuild做source→常规DEX/资源/Manifest重建→zipalign→固定用户测试签名→最终包验证。检查包名、四位build、签名、ABI/资产与SHA。
- [ ] 雷电online且旧包/数据状态确认后覆盖安装，不卸载/清数据；验证VM实读四位build、新暂存/失败分类和在途快照。真实发送使用授权测试账号/无敏感测试素材，不能操作用户短信或重复非幂等发送。 **状态：部分完成：19:29覆盖安装成功且firstInstallTime保留；21:40:21 VM实读2180、enabled、checkpoint和真实TLS失败成功。新spool的401/离线恢复由单元测试证明，尚未以此设备真实账号完整复现补报。**
- [ ] 分别实测聊天入口、文字、短视频成功/失败重试、弱网恢复补报、前后台恢复；以同根记录定位真实阶段，保持E2EE/旧数据。需要用户完成的账号动作只阻断对应验收。 **状态：部分完成：21:45闭集快照已有实际conversation_open及message_send成功，另有sync processing6750ms长尾；尚未完整覆盖短视频失败/重试、弱网恢复与通话，不从typed message_send推断具体消息内容或媒介。公开ready200和单元测试不能代替其余业务验收。**
- [ ] 对照关闭/启用诊断的CPU/内存/帧数据，记录测量窗口与profile条件；Debug时长不当作Release性能结论。 **状态：未完成：没有Release/Profile真机成对窗口，当前Debug记录不能证明量化CPU/内存开销达标。**
- [ ] Android/iOS正式包各自构建/签名/真机与分发验收；未构建的一端明确为未交付，不把源码已合并当作正式用户已获得修补。 **状态：本轮范围外且未交付：只安装雷电Debug，不声明正式Android/iOS已获得修补。**

## 门禁命令与预期结果

每次PowerShell7会话先设置UTF-8无BOM和PYTHONUTF8/PYTHONIOENCODING；在指定工作目录运行，结果必须记录真实退出码/数量/skip。以下为计划门禁命令；本轮实际退出码及日志见下方结果与交付验收，不以命令清单本身证明通过。最终Flutter门禁恢复原锁文件后使用 `--no-pub`。

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

实际：完整analyze `No issues found` / exit0；Matrix 2180 passed / 9条件skip、完整Flutter 4549 passed / 9条件skip均exit0。API/Worker 2956 passed / 75条件skip / 1既有弃用warning，exit0；最后真实路由增量另以226专项、两worker候选和生产gate验收。infra224及mobile238/1skip均exit0。`verify.ps1` exit1：Repository/Deployment/Template通过，隔离工作树缺 `.env` 导致配置渲染停止；未复制生产secret凑门禁。失败/skip原因及证据复用范围见[交付验收](../../verification/2026-09-26-network-diagnostics-remediation.md)。

## 最终验收映射

| ID | 验收证据 |
| --- | --- |
| N01/N02 | N01未恢复：13 SSH认证前超时、入口待确认；N02已同窗对照，真实App TLS失败已捕获，具体机制仍待定位 |
| N03/N04 | N03完成：有界探针、失败/缺测分母和两点多分钟实证；N04只有现有两点短窗，三运营商/24h/7天未完成 |
| C01/C02 | 同根多记录不丢、ACK只扣快照、100并发、挂住/观察超期仍有证据 |
| C03/C04 | 会话所有入口、视频重试/Outbox、网络错误真实分类、慢帧必留 |
| C05/C06 | 实际media-index SQL、setup/active通话尖峰和语义摘要通过；SDK内部阶段/真实firstPacket/独立reconnect保持unsupported，Release总体分母未实现 |
| S01/S02 | 严格旧新协议、受保护快照、运行镜像request/SQL接线实证 |
| R01 | 最终APK18/18验证、固定签名、2180保留数据安装及VM实读通过；已有会话/发送实测，短视频完整重试/弱网/通话及Profile对照待执行，正式两端未发布 |

所有日志与字段闭合；没有消息、身份、token、原始room/event/txid、路径、媒体、SQL、SDP、ICE或E2EE数据。尚无真实边界的数据保持unsupported。风险与回退见设计第7节。

## 装机反馈后的2181最小纠正（同一授权）

用户新视频发送及一次同气泡重试失败；目前2180缺少可关联记录，不按一般TLS或旧文字成功推断视频原因。追加TDD修正既有诊断队列满载尾部淘汰（含legacy网络错误）、容量满根上下文永久缺失、forward/prepared SDK观测、SDK-only重试根/计数/在途保留。queued retry/no-op不得生成SDK完成或ACK；通过公开可选回调在真正sendAgain/sendEvent边界观测，逻辑时间线按既有路由转发。完成规格→质量安全复核后冻结2181、重新执行变化输入的Flutter完整门禁、固定签名重建与保留数据装机，保持业务重试/SDK/E2EE/节点池不变。真实视频业务原因仍须新包同根测量；2180的门禁不能代替2181结果。

### 2181冻结与门禁增量

23:07:04纠正源码冻结/独立复核PASS；28专项、最终完成标记前321回归及root完整analyze无issues/Matrix2204/full4586均exit0，9条件skip。五分钟租约/容量释放不再提前编造waitingNetwork终态，诊断异常不改变业务结果。23:13verify.ps1仍因缺.env exit1，政策/模板PASS。下一步固定签名重建、保留数据装机和同根视频实测；未把诊断缺陷修正称为视频业务故障修复。

### 2181实测与2182最小进程环境对照

2181已23:26保留数据安装/VM实读；用户新视频root700ms在normal/aggressive两次native转码失败，未上传或SDK发送。修正快速失败classifier遗漏并做原生x64对照，代码只用已有ABI支持，不改codec策略/原视频禁止绕过/20MB/H264/AAC/E2EE。2182四位字段已核对ref/task占用，独立x64重建门禁18项仍保持；完整源码/装机/用户实测待后续真实门禁。

2182最终源码门禁于2026-09-27 00:38:21完成：analyze No issues/Matrix2204/full4593 exit0、9条件skip。分类器21专项及独立复核PASS；仅测试的held-forward同步修正4专项通过，初次全量失败保留。下一步提交冻结并执行原生x64重建/装机/用户实测，具体ABI因果不先行定论。

### 原生模拟器对照的交付输入调整（2026-09-27）

设备已由用户批准的账号任务先行安装0.4.15/2182。为保留该版本功能，本任务按其source-freeze055c67…的1346移动文件核验合并，只保留本任务三个post6f诊断/测试差异，改用0.4.15/2183原生x86_64。账号规则/鉴权实现复用已有批准设计及ADR（2026-09-26-mutable-changliao-username），不新增本任务的认证规则或生产发布。完整合并输入门禁→固定签名18项重建→ELF独立检查→当前设备版本/内容漂移守卫→保留数据安装→用户相同短片的新选择实测。任何新codec结论只能按实际trace，不把原生创建探针或同步慢帧当作转码成功。