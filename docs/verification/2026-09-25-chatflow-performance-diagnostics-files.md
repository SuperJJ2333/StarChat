# ChatFlow 性能诊断逐文件修改清单

此清单对应本地隔离工作树最终候选。每行说明该文件在本次改造中的用途；实际门禁与限制见[验证报告](2026-09-25-chatflow-performance-diagnostics.md)。

| 文件 | 本次目的 |
| --- | --- |
| `apps/mobile_flutter/lib/app_home.dart` | 聊天打开、恢复与导航入口传递同一操作 trace。 |
| `apps/mobile_flutter/lib/core/business_api_client.dart` | 共用认证请求入口接入 HTTP 性能客户端。 |
| `apps/mobile_flutter/lib/core/business_api_performance_client.dart` | HTTP 总时长、错误、重试与安全请求关联头。 |
| `apps/mobile_flutter/lib/core/chat_diagnostics.dart` | 复用后台上传；有界批次与按操作 ID 一致采样。 |
| `apps/mobile_flutter/lib/core/chat_diagnostics_scope.dart` | 账号切换清理诊断会话与本地指标。 |
| `apps/mobile_flutter/lib/core/network_state_manager.dart` | 传输、服务可达与应用网络状态分离。 |
| `apps/mobile_flutter/lib/core/performance_metrics.dart` | 复用帧指标并提供操作/阶段分位数及本地快照。 |
| `apps/mobile_flutter/lib/core/performance_trace.dart` | 同 ID、单调标记、有界 trace 与子操作上下文。 |
| `apps/mobile_flutter/lib/core/performance_trace_model.dart` | 封闭操作、阶段、字段、阈值与纯函数分类。 |
| `apps/mobile_flutter/lib/features/contacts/contacts_page.dart` | 联系人首帧/内容/远端刷新及 API 子请求关联。 |
| `apps/mobile_flutter/lib/features/matrix/app_resume_performance_observer.dart` | 前后台恢复的帧、连接、同步及房间就绪里程碑。 |
| `apps/mobile_flutter/lib/features/matrix/call_audio_route_coordinator.dart` | 通话路由日志统一标签并按诊断开关输出。 |
| `apps/mobile_flutter/lib/features/matrix/call_controller.dart` | 通话建立 trace 与现有质量监控关联。 |
| `apps/mobile_flutter/lib/features/matrix/call_diagnostics.dart` | 复用通话阶段诊断并限制日志。 |
| `apps/mobile_flutter/lib/features/matrix/call_quality_monitor.dart` | 复用 getStats，输出真实质量与 TURN 摘要。 |
| `apps/mobile_flutter/lib/features/matrix/image_picker_page.dart` | 最近图片页面首帧与内容就绪。 |
| `apps/mobile_flutter/lib/features/matrix/matrix_call_adapter.dart` | 信令/ICE 状态与安全通话日志接线。 |
| `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart` | 视频准备/发送与 Matrix 状态的实际测量边界。 |
| `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart` | 聊天列表首帧、快照与刷新阶段。 |
| `apps/mobile_flutter/lib/features/matrix/matrix_sync_phase_metrics.dart` | 复用同步等待/处理/清理，增加完整周期 trace。 |
| `apps/mobile_flutter/lib/features/matrix/matrix_sync_watchdog.dart` | 同步错误、重连、软唤醒和硬重启计数。 |
| `apps/mobile_flutter/lib/features/matrix/media_cache.dart` | 缓存来源、共享在途与媒体总加载计时。 |
| `apps/mobile_flutter/lib/features/matrix/media_load_scheduler.dart` | 真实队列等待、并发数、视频并发与有效优先级。 |
| `apps/mobile_flutter/lib/features/matrix/pending_conversation_page.dart` | 离线 pending 会话沿用打开 trace 并安全收尾。 |
| `apps/mobile_flutter/lib/features/matrix/prepared_chat_video.dart` | 视频封面准备阶段标记。 |
| `apps/mobile_flutter/lib/features/matrix/room_navigation_coordinator.dart` | 导航请求携带原始操作 trace，不创建新 ID。 |
| `apps/mobile_flutter/lib/features/matrix/room_opening_policy.dart` | 打开来源与结果日志脱敏。 |
| `apps/mobile_flutter/lib/features/matrix/room_page.dart` | 房间 attach、本地 timeline、首帧与真实 sync 阶段。 |
| `apps/mobile_flutter/lib/features/matrix/room_timeline_controller.dart` | Outbox 发送、准入、Matrix ACK/可见与有界重试关联。 |
| `apps/mobile_flutter/lib/features/matrix/turn_credentials_cache.dart` | TURN 发现日志仅诊断模式输出且不含凭据。 |
| `apps/mobile_flutter/lib/features/matrix/video_poster_diagnostics.dart` | 封面来源封闭分类与原诊断复用。 |
| `apps/mobile_flutter/lib/features/matrix/video_poster_pipeline.dart` | 封面实际加载路径与 cache/source 计时。 |
| `apps/mobile_flutter/lib/features/matrix/video_transcode.dart` | 视频验证、排队与转码实际阶段。 |
| `apps/mobile_flutter/lib/features/moments/moments_page.dart` | 朋友圈缓存、首帧、刷新与 API 子请求关联。 |
| `apps/mobile_flutter/lib/features/profile/profile_page.dart` | 个人资料首帧、内容与 API 子请求关联。 |
| `apps/mobile_flutter/lib/features/search/global_search_controller.dart` | 本地搜索操作阶段与结果桶。 |
| `apps/mobile_flutter/lib/features/search/global_search_page.dart` | 搜索页首帧、结果渲染与 API 子请求关联。 |
| `apps/mobile_flutter/lib/features/search/local_message_search_repository.dart` | 本机搜索阶段计时且不记录查询词。 |
| `apps/mobile_flutter/lib/features/wallet/manual_wallet_page.dart` | 钱包缓存首屏与独立远端刷新操作。 |
| `apps/mobile_flutter/lib/main.dart` | 应用启动首帧 trace 与诊断初始化。 |
| `apps/mobile_flutter/test/core/business_api_diagnostics_test.dart` | 上传批次大小、采样与兼容性回归。 |
| `apps/mobile_flutter/test/core/business_api_performance_test.dart` | HTTP 计时、401 重试、父 ID 与并发隔离。 |
| `apps/mobile_flutter/test/core/chat_diagnostics_scope_test.dart` | 账号切换清理诊断与指标。 |
| `apps/mobile_flutter/test/core/network_state_manager_test.dart` | 传输/服务/Matrix 状态分离。 |
| `apps/mobile_flutter/test/features/contacts/contacts_group_entry_test.dart` | 联系人页面首帧、刷新及 API 同 ID。 |
| `apps/mobile_flutter/test/features/matrix/account_client_selection_test.dart` | Matrix 账号/客户端选择与诊断隔离。 |
| `apps/mobile_flutter/test/features/matrix/app_resume_performance_observer_test.dart` | 恢复生命周期真实里程碑。 |
| `apps/mobile_flutter/test/features/matrix/call_audio_route_coordinator_test.dart` | 通话路由日志门禁与标签。 |
| `apps/mobile_flutter/test/features/matrix/call_diagnostics_logging_test.dart` | 通话日志安全门禁。 |
| `apps/mobile_flutter/test/features/matrix/call_quality_and_gate_test.dart` | getStats 质量与原通话门禁回归。 |
| `apps/mobile_flutter/test/features/matrix/call_quality_monitor_performance_test.dart` | 丢包率、TURN 与真实样本边界。 |
| `apps/mobile_flutter/test/features/matrix/call_setup_adapter_signal_test.dart` | 信令和 ICE 阶段回调。 |
| `apps/mobile_flutter/test/features/matrix/call_setup_performance_trace_test.dart` | 通话建立同 ID 时序。 |
| `apps/mobile_flutter/test/features/matrix/image_picker_performance_test.dart` | 最近图片首帧与内容就绪。 |
| `apps/mobile_flutter/test/features/matrix/matrix_home_snapshot_refresh_test.dart` | 聊天列表缓存首屏和远端刷新。 |
| `apps/mobile_flutter/test/features/matrix/matrix_sync_phase_metrics_test.dart` | 同步 wait/processing/cleanup 与周期总时长。 |
| `apps/mobile_flutter/test/features/matrix/matrix_sync_watchdog_test.dart` | 同步错误、软唤醒、重连、硬重启。 |
| `apps/mobile_flutter/test/features/matrix/media_load_scheduler_test.dart` | 排队、并发、视频数及优先级。 |
| `apps/mobile_flutter/test/features/matrix/outbox_send_flow_test.dart` | 发送持久化、重试、ACK 和可见时序。 |
| `apps/mobile_flutter/test/features/matrix/pending_conversation_outbox_test.dart` | pending 会话与 Outbox 保持原行为。 |
| `apps/mobile_flutter/test/features/matrix/profile_message_route_wiring_test.dart` | 资料入口到房间导航接线。 |
| `apps/mobile_flutter/test/features/matrix/room_open_performance_trace_test.dart` | 本地/pending 会话打开共用操作 ID。 |
| `apps/mobile_flutter/test/features/matrix/room_opening_policy_test.dart` | 来源策略与敏感日志保护。 |
| `apps/mobile_flutter/test/features/matrix/room_page_anchor_navigation_test.dart` | RoomPage 首帧、timeline 和同步阶段。 |
| `apps/mobile_flutter/test/features/matrix/turn_credentials_cache_test.dart` | TURN 凭据不出日志。 |
| `apps/mobile_flutter/test/features/matrix/video_poster_performance_trace_test.dart` | 封面操作来源与阶段。 |
| `apps/mobile_flutter/test/features/matrix/video_poster_pipeline_test.dart` | 封面缓存及加载管线回归。 |
| `apps/mobile_flutter/test/features/matrix/video_send_limit_test.dart` | 视频尺寸门禁与准备阶段。 |
| `apps/mobile_flutter/test/features/matrix/video_transcode_performance_trace_test.dart` | 视频转码真实边界。 |
| `apps/mobile_flutter/test/features/moments/moment_video_test.dart` | 朋友圈视频回归及分析器 lint 修正。 |
| `apps/mobile_flutter/test/features/moments/moments_flow_test.dart` | 朋友圈缓存/刷新及 API 同 ID。 |
| `apps/mobile_flutter/test/features/profile/profile_controller_test.dart` | 个人资料首屏与请求关联。 |
| `apps/mobile_flutter/test/features/search/global_search_controller_test.dart` | 搜索耗时与结果桶。 |
| `apps/mobile_flutter/test/features/search/global_search_page_test.dart` | 搜索页面首帧/结果与请求关联。 |
| `apps/mobile_flutter/test/features/search/local_message_search_performance_test.dart` | 本地搜索不泄露查询词。 |
| `apps/mobile_flutter/test/features/wallet/manual_wallet_flow_test.dart` | 钱包首屏与独立刷新同 ID。 |
| `apps/mobile_flutter/test/features/wallet/wallet_entry_cache_test.dart` | 钱包缓存首屏与后台刷新。 |
| `apps/mobile_flutter/test/performance/app_startup_trace_test.dart` | 启动首帧操作 trace。 |
| `apps/mobile_flutter/test/performance/media_cache_metrics_test.dart` | 媒体缓存、共享在途与总耗时。 |
| `apps/mobile_flutter/test/performance/performance_bottleneck_classifier_test.dart` | 各层瓶颈与 unknown 分类纯函数。 |
| `apps/mobile_flutter/test/performance/performance_timing_summary_pages_test.dart` | 会话、恢复及页面真实区间摘要。 |
| `apps/mobile_flutter/test/performance/performance_trace_test.dart` | 阶段、ID、并发、容量、隐私和帧关联。 |
| `apps/mobile_flutter/test/performance/performance_trace_upload_test.dart` | 闭合操作上报与旧服务兼容。 |
| `docs/performance/chatflow-performance-diagnostics.md` | 实施前审计矩阵、数据流、分类和故障手册。 |
| `docs/runbooks/client-diagnostics.md` | 客户端诊断上传与服务端快照运行手册。 |
| `docs/superpowers/plans/2026-09-25-unified-performance-diagnostics.md` | 获准规格的分步实施计划与文件所有权。 |
| `docs/verification/2026-09-25-chatflow-performance-diagnostics-files.md` | 逐文件列出本次修改及其用途。 |
| `docs/verification/2026-09-25-chatflow-performance-diagnostics.md` | 真实门禁、失败返工、隐私复审与限制。 |
| `docs/workflow/current-state.md` | 在跨会话恢复索引登记本地候选与证据。 |
| `docs/workflow/tasks/2026-09-25-unified-performance-diagnostics.md` | 独立任务台账、状态、证据和下一步。 |
| `packages/api-contracts/openapi/liuhetong-v1.yaml` | 同步闭合诊断 schema 和受保护性能快照接口。 |
| `services/business-api/app/api/client_diagnostics.py` | 严格校验匿名性能操作与后台批次。 |
| `services/business-api/app/api/maintenance.py` | 复用维护令牌鉴权边界。 |
| `services/business-api/app/api/media_platform.py` | 媒体平台快照接入有界分位数。 |
| `services/business-api/app/api/performance_diagnostics.py` | 维护权限下读取本进程性能快照。 |
| `services/business-api/app/core/database.py` | SQL 实际执行时间、池使用量和慢查询计数。 |
| `services/business-api/app/core/tracing.py` | route template 请求计时与短期匿名操作关联。 |
| `services/business-api/app/main.py` | 注册维护性能快照路由。 |
| `services/business-api/app/modules/media/metrics.py` | 媒体分位数摘要复用现有窗口。 |
| `tests/business_api/media_platform/test_media_domain_core.py` | 验证媒体平台分位数与原有行为。 |
| `tests/business_api/test_client_diagnostics.py` | 验证诊断闭合字段、隐私、限流与兼容性。 |
| `tests/business_api/test_database.py` | 验证 SQL 时间和连接池指标边界。 |
| `tests/business_api/test_performance_snapshot_api.py` | 验证性能快照维护鉴权与内容。 |
| `tests/business_api/test_tracing_metrics.py` | 验证路由模板计时与匿名短期关联。 |
