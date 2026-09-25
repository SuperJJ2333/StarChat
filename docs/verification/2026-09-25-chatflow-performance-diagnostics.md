# ChatFlow 全链路性能诊断：本地候选验证

## 范围与输入

- 用户规格：2026-09-25「ChatFlow 全链路卡顿诊断与性能监控改造」。只做观察、计时、关联、分类；无发包、真机测试或生产部署授权。
- 隔离工作树：`C:/Users/Administrator/.codex/worktrees/performance-diagnostics-20260925/StarChat`，分支 `codex/performance-diagnostics`，基线 `2442f0ab`。主工作区既有未提交改动未触碰。
- 实施前诊断能力矩阵、故障判断手册、数据流、支持操作和隐私边界见 [性能诊断手册](../performance/chatflow-performance-diagnostics.md)。
- 工具环境：Windows、PowerShell 7.6.5、Flutter 3.44.9、Dart 3.12.2、Python 3.12.10、Docker 29.2.1。Flutter 测试从隔离工作树映射的 `X:` 盘运行，规避 Windows 长路径；依赖锁未用于升级。
- 源码输入：基线 commit `2442f0ab41707808d40f8a74bcc1e9939e819dd0`；98 个改动代码/测试/契约文件加 `pubspec.lock` 的 [SHA-256 清单](artifacts/2026-09-25/performance-diagnostics/source-sha256.txt) 自身 SHA-256 为 `46f5207d16ddbc6a61a1f7d04e9ebbf4bd28975bdb62882f33fbac7d0195c695`；`pubspec.lock` SHA-256 为 `a2af1ef677f2bee3af4d012d15eb5dc2492d220bf66eabb27ccf62c17fd733fc`，Git 状态无锁文件改动。文档不在该源码清单内。

## 代码与数据流

用户动作创建一次随机 UUID v4；类型化 stage 只写内存的单调时钟偏移。现有 `PerformanceMetrics` 负责帧计数与有界本地操作/阶段分位数，现有 `ChatDiagnostics` 负责有界、按正常 5% / 慢及错误 100% 抽样后的后台上传。服务端接收端只收闭合 schema；短期请求关联用独立的 `X-ChatFlow-Performance-Id`，不写入业务审计 `X-Trace-Id`。请求、SQL 执行及媒体快照有 P50/P95/P99/MAX。整个采集路径不新增数据库查询或磁盘/网络 IO；上传仍由已有后台批次处理。

## 已执行验证

| 门禁 | 命令或检查 | 结果 | 证据 |
| --- | --- | --- | --- |
| 核心 trace/classifier TDD | 聚焦 Flutter test | RED→GREEN；阶段、并行 100 条、容量、隐私、分类、生命周期等通过 | 本任务执行记录 |
| 消息发送重试 TDD | `flutter test test/features/matrix/outbox_send_flow_test.dart --no-pub` | RED→GREEN；40/40，退出 0 | 本任务执行记录 |
| Matrix 负责模块 | 6 个聚焦测试文件 | 58/58，退出 0；源码与测试 Dart analyze 均退出 0 | 本任务执行记录 |
| 通话路由日志 | 单文件 | RED 退出 1→GREEN 9/9，退出 0 | 本任务执行记录 |
| Flutter 静态分析 | `flutter analyze lib test --no-pub` | 最终采样修正后 `No issues found`，退出 0 | [最终分析日志](artifacts/2026-09-25/performance-diagnostics/flutter-analyze-sampling-final.log) |
| Matrix 全套 | `flutter test test/features/matrix --no-pub --reporter expanded` | 最终采样修正后 2035/2035，退出 0 | [最终 Matrix 日志](artifacts/2026-09-25/performance-diagnostics/flutter-matrix-sampling-final.log) |
| Flutter 全套 | `flutter test --no-pub --reporter expanded` | 最终采样修正后 4128/4128，退出 0 | [最终 Flutter 全量日志](artifacts/2026-09-25/performance-diagnostics/flutter-all-sampling-final.log) |
| 仓库 verify 首次 | `pwsh -NoProfile -File scripts/verify.ps1` | 退出 1：隔离工作树缺 `.env`，配置渲染前置条件失败；repository/deployment/template 三步通过，后续未执行 | [首次 verify 日志](artifacts/2026-09-25/performance-diagnostics/verify.log) |
| 维护诊断接收端 | `py -3.12 -m pytest tests/business_api/test_client_diagnostics.py -q` | 149/149，退出 0；旧 Starlette deprecation warning 1 条 | 服务端代理聚焦记录 |
| Business API / Worker 全套 | `py -3.12 -m pytest tests/business_api tests/business_worker -q` | 2861 通过、74 跳过、1 条既有 Starlette deprecation warning，退出 0 | [后端全套日志](artifacts/2026-09-25/performance-diagnostics/business-api-worker-tests.log) |
| 仓库 policy/deployment/template | 对应 `verify.ps1` 前三步 | 退出 0；在脚本日志中 | [首次 verify 日志](artifacts/2026-09-25/performance-diagnostics/verify.log) |
| infra | `py -3.12 -m pytest tests/infra -q` | 144/144，退出 0；X: 的 pytest cache 写入 warning 1 条 | [infra 日志](artifacts/2026-09-25/performance-diagnostics/infra-tests.log) |
| 推送桥 | `py -3.12 -m pytest tests/getui_bridge -q` | 28/28，退出 0；依赖弃用 warning 2 条 | [推送桥日志](artifacts/2026-09-25/performance-diagnostics/getui-tests.log) |
| Matrix bot | `py -3.12 -m pytest tests/matrix_bot -q` | 9/9，退出 0 | [bot 日志](artifacts/2026-09-25/performance-diagnostics/matrix-bot-tests.log) |
| Flutter 边界 | `py -3.12 -m pytest tests/mobile -q` | 108 通过、1 跳过，退出 0 | [移动边界日志](artifacts/2026-09-25/performance-diagnostics/mobile-boundary-tests.log) |
| UI 契约 | `py -3.12 scripts/verify_ui_contract.py` | 32 组件/403 屏，退出 0 | [UI 契约日志](artifacts/2026-09-25/performance-diagnostics/ui-contract.log) |
| Python AST / API import | 与 `verify.ps1` 相同扫描和导入 | 269 文件解析、导入成功，均退出 0 | 本任务分项执行记录 |
| Alembic / OpenAPI / Compose | 离线迁移、`export_openapi.py --check`、`docker compose --env-file .env.example config --quiet` | 单一 head `0087`，三项均退出 0 | [离线迁移日志](artifacts/2026-09-25/performance-diagnostics/alembic-offline.sql.log)及分项执行记录 |
| 最终仓库策略与任务文档链接 | `Test-RepositoryPolicy.ps1`；只检查本任务五份文档与恢复索引首节 | 仓库策略退出 0；19 个任务链接存在，退出 0 | 本任务执行记录 |

首次 Matrix 全套曾因源码形状 guard 两项失败；guard 调整后定向 28/28 和最终 2035/2035 通过。初次 Flutter 分析的两个测试 lint info 已补花括号，最终分析为零问题。长路径引发的媒体测试构建失败不是业务断言，使用 `X:` 后该文件 13/13 通过。所有失败都保留为返工证据，不算通过。`verify.ps1` 需要隔离工作树根目录的 `.env`；尝试临时从 `.env.example` 创建并在结束清理的命令被自动审批审查以 `blocked by policy` 拒绝，没有执行。故本报告只声称脚本首次真实退出码 1；配置渲染烟测未执行，其他脚本步骤由上述分项检查覆盖。

全份 `docs/workflow/current-state.md` 的历史章节另有 16 个既有失效链接；它们位于本任务新节之外。本任务新增文档和索引新节的 19 个本地链接均存在。

## 规格与质量/安全复审

- 先核对实施前矩阵及用户操作链是否有真实标记，再复审容量、隐私和业务不变量。Matrix 同步、通话 getStats、帧时序、媒体 Scheduler 均复用已有能力，没有平行采集器。
- 关键修正：Business API 的性能 ID 不复用会进入金融/身份审计的 `X-Trace-Id`；HTTP 状态 5xx 的客户端总耗时不冒充服务端处理耗时；正常 Matrix `/sync` 长轮询不凭单次 response wait 判故障；消息等待网络后成功 ACK 的可见阶段不提前标记；早退页面会结束或释放 trace。最终质量复审发现慢 Matrix 等待/处理的成功聊天打开只按 5% 普通采样；先以测试复现退出 1，再把真实 `sync_wait`/response wait/processing 与集中阈值加入 100% 慢事件保留，聚焦 9/9 退出 0。随后复现正常长轮询及健康通话因总时长而 100% 上传的问题（RED 退出 1），改为用真实处理耗时及质量指标判慢，GREEN 10/10 退出 0；普通样本仍按 5% 抽样。
- 服务端 OpenAPI 变更由闭合 performance operation schema、维护快照与仅 operation 的批次兼容组成，没有发现无关业务契约漂移。
- 最后一轮只读独立复审核对了采样分支、同 ID 会话守卫、关闭诊断时的 HTTP 直通、服务端性能头及敏感业务差异；未发现新的 P1 隐私或功能问题，`git diff --check` 退出 0。该结论不替代真机或线上性能数据。

## 真实边界与限制

- 当前 Flutter HTTP/Matrix SDK 没有可信 DNS/TCP/TLS/TTFB 分段，保持 null/unsupported。HTTP 泛型 timeout/SocketException 只按确证类型分类，不伪称 DNS 或服务器错误。
- 媒体缓存回调同时做下载与解密，现有生产路径不能分别标 `download_ms` / `decrypt_ms`；图片解码也没有可信独立 hook。能实测 Scheduler 排队、缓存来源与合并加载总耗时，不能据此单独断定 CDN 慢。
- 视频 SDK `sendFileEvent` 合并上传与事件发送，缺少 `videoUploadDone` 真实边界；合并时段不得拆成两个数字。WebRTC 首包、ICE gathering 细分没有生产回调则缺席。
- Matrix 本地 timeline 恢复总耗时不能当作纯 SQL/锁等待；搜索当前以内存索引为主，只有真实数据库边界可记录数据库阶段。服务端 pool checkout 等待、外部依赖时延及跨 worker 聚合尚无数据。
- 页面缓存已就绪时可在首帧和缓存内容后结束操作；随后后台刷新属于独立观察，可能不在同一条页面 trace。消息发送同控制器内五分钟/容量内重试保留 ID，跨进程或 pending composer 未恢复同一 ID。
- 没有真实用户样本、弱网/跨境通话设备采样、CPU/内存基准或线上启用记录。文档中的示例数值只说明解读方法，不是测量结果。

## 文件清单

本次 104 个源码、测试及文档文件的逐文件用途见[修改文件清单](2026-09-25-chatflow-performance-diagnostics-files.md)。源码/锁 SHA 如上。
