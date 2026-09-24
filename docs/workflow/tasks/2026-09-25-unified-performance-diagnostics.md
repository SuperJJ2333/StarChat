# ChatFlow 全链路性能诊断

## 恢复入口

- 目标、授权与边界：用户 2026-09-25 的完整性能诊断规格；只做 observe/measure/correlate/classify，保留 Offline First、Outbox、E2EE、财务和现有诊断入口；未要求部署或发包。
- 关联计划：`../../superpowers/plans/2026-09-25-unified-performance-diagnostics.md`；审计及手册：`../../performance/chatflow-performance-diagnostics.md`。
- 当前状态：实现与本地门禁完成。后端 API/Worker 全套 2861 通过、74 跳过、退出 0；最终采样修正后的 Flutter analyze 零问题、Matrix 2035/2035、Flutter 全套 4128/4128，均退出 0。仓库 `verify.ps1` 因本工作树无 `.env` 在配置渲染步骤退出 1，已独立执行无需该文件的后续门禁；尚未构建、安装或发布。
- 负责人、工作树、文件所有权：root 协调；独立 worktree `C:/Users/Administrator/.codex/worktrees/performance-diagnostics-20260925/StarChat`，分支 `codex/performance-diagnostics`，基线 `2442f0ab`；所有权见计划。
- 最后更新时间：2026-09-25 04:20 Asia/Hong_Kong。
- 下一条具体操作：核对本地候选提交和工作树；若后续需要真机弱网/通话采样或发布，另行按设备与发布工作流执行。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| PERF-01 | 统一 ID、阶段、帧、有界与隐私 | 类型化 trace、有界样本、现有帧指标/上传聚合已接通 | 核心单测 RED→GREEN；Flutter analyze 零问题、全套 4128/4128 | 未要求 | 未真机 |
| PERF-02 | 会话打开与恢复 | 本地 room/pending、首帧/内容/真实 sync 分段、后台恢复里程碑已接通 | 会话早退/失败、resume、同步阶段聚焦 RED→GREEN；Matrix 全套 2035/2035 | 未要求 | 未真机 |
| PERF-03 | 发送/Matrix/媒体/通话 | 发送链、同步阶段、Scheduler/缓存/视频、getStats 与 call setup 已接通 | 发送 40/40、Scheduler 10/10、通话路由 9/9、Matrix 全套 2035/2035，均退出 0 | 未要求 | SDK 合并上传/事件及下载/解密等边界不可拆分，详见手册 |
| PERF-04 | API/页面/服务端 | 共用 HTTP seam、父操作 ID、首帧/内容、route-template/数据库分位数、维护快照已接通 | 页面/API 74/74、接收端 149/149；后端全套 2861 通过、74 跳过，退出 0 | 未要求 | 未连接生产 |
| PERF-05 | 分类、摘要、文档、全量门禁 | 分类器及本地/服务端摘要与故障手册已写；慢 Matrix 等待成功会话 100% 保留，正常长轮询/健康通话按 5% 采样 | 分类器 13/13；Flutter analyze/Matrix/全套退出 0；`verify.ps1` 真实退出 1（缺 `.env`），后续独立门禁详见报告 | 未要求 | 未进行设备性能基准 |

## 基线与阶段计时

- 2026-09-25：主目录有其他任务未提交改动，使用隔离 worktree，不覆盖主目录。审计搜索命中 98 个相关文件。
- Flutter 3.44.9 / Dart 3.12.2；基线命令 `flutter test test/performance/performance_metrics_test.dart test/core/chat_diagnostics_test.dart --reporter expanded` 退出码 0，9 项通过；首次 `pub get` 解析依赖，后续须检查 lock 文件哈希和改动。
- 本任务无设备安装、发包、生产变更或真实用户诊断。最终证据见 `docs/verification/2026-09-25-chatflow-performance-diagnostics.md`；逐文件目的见其修改文件清单。

## 版本与证据

| 平台/服务 | 实际版本 | 来源 commit | 发布产物 | 文件位置及 SHA | 发布观察 |
| --- | --- | --- | --- | --- | --- |
| 本地隔离工作树 | Flutter 3.44.9 / Dart 3.12.2；Windows / PowerShell 7.6.5 / Python 3.12.10 / Docker 29.2.1 | 基线 `2442f0ab`，分支 `codex/performance-diagnostics` | 无 | 源码清单 SHA-256 `46f5207d16ddbc6a61a1f7d04e9ebbf4bd28975bdb62882f33fbac7d0195c695`；锁 SHA-256 `a2af1ef677f2bee3af4d012d15eb5dc2492d220bf66eabb27ccf62c17fd733fc`，详见验证报告 | 未发布 |

聚焦 RED→GREEN 证据：核心 trace 阶段/会话隔离/缓冲与分类器；会话失败/退页；恢复同步状态；消息发送异常及手动重试；Matrix 真实 getStats/TURN 日志；API、页面、服务端契约。已执行的初次 Matrix 全套因两处源码形状 guard 失败，针对修改后的 guard 聚焦 28/28 通过；最终全量重新运行，不把初次运行算通过。长路径造成的 Windows MAX_PATH 测试失败通过将隔离工作树映射为 `X:` 规避，原测试从 `X:` 13/13 通过。首次 `flutter analyze lib test --no-pub` 因两个测试 lint info 退出 1，修正花括号后复跑为 `No issues found` / 退出 0；最终源码还将再跑一次。

## 阶段计时

| 阶段 | 开始（Asia/Hong_Kong） | 结束 | 类型/并行 | 结果及耗时依据 | 下一步 |
| --- | --- | --- | --- | --- | --- |
| 隔离与审计 | 2026-09-25，精确开始时间未记录 | 同日，精确结束时间未记录 | 主动，审计与计划 | 基线及 98 文件命中写入性能手册；不推算分钟数 | TDD 实现 |
| 实现与聚焦验证 | 2026-09-25，精确开始时间未记录 | 2026-09-25 04:02 前 | root / Matrix / UI-API / Server 并行，含返工 | 各聚焦命令及 RED→GREEN 如上；不将并行工作相加成墙钟 | 全量门禁 |
| Flutter 全量验证 | 2026-09-25 03:19 后首次完整运行；各次精确时刻见日志 | 2026-09-25 04:20 前最终完成 | 工具执行；多次重跑因新增真实边界和安全复审修正 | analyze 无问题、Matrix 2035/2035、Flutter 4128/4128，均退出 0 | 文档/提交 |
| 仓库分项验证 | 2026-09-25 03:42 后 | 2026-09-25 04:14 前 | 工具执行，与 Flutter 最终门禁部分并行 | `verify.ps1` 缺 `.env` 退出 1；后端 API/Worker 2861 通过、74 跳过、退出 0；其余已完成分项退出 0，见报告 | Flutter 全量复跑 |

总墙钟：精确开工时刻未记，保持未知；重复工作：首次 Windows 长路径与两个源码 guard 导致定向返工，已在 `X:` 和聚焦测试中修正。完成后的命令、输入 hash、依赖锁 SHA、通过/失败数见 `docs/verification/` 的本任务报告。

## 交接与回退

- 已确认：现有帧、同步、媒体、通话和上传诊断可复用；缺的是跨层同一操作 ID 与真实分段。Matrix 长轮询、HTTP 服务端耗时、媒体混合回调均不能无证据猜分段。
- 待办：本地提交后核对工作树；设备性能采样和发布没有在本任务执行。源码和依赖锁哈希已记录；本任务文档 19 个链接通过。规格符合性复审已先做，质量/安全复审发现慢同步成功会话抽样缺口及正常长轮询/健康通话过量上传，并以 RED→GREEN 修复；最后独立只读复审未发现新的 P1 隐私或功能问题。
- 已发布与仅候选：全部为本地隔离工作树候选；未构建/安装/部署/分发。
- 回退：不涉及数据库迁移与线上发布；丢弃本隔离工作树即可回到 `2442f0ab`，不触碰主工作区的既有未提交修改。
- 运行中命令：无；没有本任务创建的隧道或 CI。
- 下次恢复：核对 `git status`、报告与本地候选提交；若用户另行要求设备采样或发布，以当时的授权、签名及生产状态重新计划。
