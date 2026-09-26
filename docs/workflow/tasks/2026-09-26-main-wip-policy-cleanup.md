# 原 main 67 项工作区与策略拒绝审计

## 恢复入口

- 用户授权：合并其他分支到 main 并 push；检查原 main 的 67 项内容及 policy 拒绝根因；删除残余 Git 分支。
- 工作树：隔离的 merge-main-20260926；原 main 起点 b9eca8a4，已集成远端 f820d704。
- 范围：补合并已有批准工作的遗漏，归档原工作区，清理重复分支。无生产重新部署或设备装机。
- 关联批准计划：2026-09-24-refresh-release-guards；相关已完成历史任务本轮补回文档。
- 更新时间：2026-09-26，Asia/Hong_Kong。阶段精确总耗时未完整采集，不估算。

## 为什么原来没有应用 67 项

前轮只合并已提交分支，并保护根目录未提交文件，没有先逐项确认其独立功能，这是集成遗漏。不能将全部未提交内容视为未批准工作。审计发现六个已经完成且批准的续期守卫源码/测试没有提交，现补入 main；已存在的新移动实现不能被旧文件覆盖。

67 项原始状态：23 tracked modified + 44 untracked。以 Git canonical blob 比较 f820d704：12 identical、16 different、39 absent。不是 67 个未合并功能。

- 移动端 19：12 完全一致；7 旧副本已被后续实现吸收。包括冷启动与预览修复；直接覆盖会丢失性能 tracing、刷新 coalescing、身份预检及回归测试修正。
- 前端 6：保留当前 iOS 2173，不回退旧 2172 发布文案。合入独立 OTA 无 query 回归断言、注释及首页 cache key 对齐。
- 基础设施 6：补入全部源码及测试；规格后质量安全独立复审通过。
- 文档 32：补回批准历史设计、报告、交接，索引选择性补入；公告 ADR 编号冲突重编号。两个未批准的 E2EE 退役提案只归档，未实施。
- 临时文件 4：仅归档，不提交。headers.txt 含签名 URL/query 迹象，原始内容不打印或公开。

## 保全

原 67 文件均完整复制到根目录忽略路径 `docs/verification/artifacts/2026-09-26/main-wip-archive/files/`，逐文件 SHA256 比对通过；同目录 manifest.json 和 inventory.json 保存状态、hash、原 main 与 remote 身份。归档不在 Git 中。清理前再次比对，只有通过者允许恢复/移除原副本。

## blocked by policy

确认的层级：exec_command 在 CreateProcess 前拒绝一条包含 `.env` 临时复制、verify.ps1 执行和 finally 清理的组合 PowerShell 命令；未创建进程、环境文件或对应日志。普通 verify.ps1 已真实启动，因隔离树缺 .env 返回 exit 1，这是另一个独立错误。

有效配置为 approval_policy=Never、sandbox_policy=DangerFullAccess。默认本地 rules 没有 deny/prompt 规则，检查范围内没有 requirements.toml，日志也没有 rule ID 或 decision rationale。Guardian 特征开关不能证明它作出该次决定。只能定位到执行前工具策略层，不能确认具体规则，也无法证明所有历史拒绝有同一原因。

此前称其为“自动审批拒绝”过于确定，现纠正。官方文档明确 never 没有待审请求，Auto-review 因此不执行：[Auto-review](https://learn.chatgpt.com/docs/sandboxing/auto-review)。规则可在执行前阻止命令：[Rules](https://learn.chatgpt.com/docs/agent-configuration/rules)。没有关闭保护或尝试重现拒绝。

独立网络问题：本机 Git http.proxy 导致 TLS handshake 失败；使用单次 `git -c http.proxy=` 直连可以完成 fetch/push，证书校验保持。此问题不能归类为 policy 拒绝。

## 分支清理依据

已图谱合并：auth-login-2178、online-room-refresh、performance-debug-mi6、bill-balance-api-fix、refresh-restore；integration 分支在 main 更新后删除。

auth-login-six-fixes 的 03c851a5 与 performance-diagnostics 的 8d044655 不是图谱祖先，也不是相同 patch；分别经 12d7fe5b 与 c0688667 及后续提交移植。23/104 个变更路径全部存在，6/75 完全一致，其余被后续演进。独立功能审查确认内容被吸收，再删除重复 ref。原 tip 身份保存在本报告与归档；历史工作树切为 detached，不删除其未提交内容/装机证据。

## 验证

- 根工作区 guard 专项：25 passed，exit 0，0.14s。
- 本轮 integration infra/frontend：见下方最终验收结果和本地忽略日志。
- 前轮同一 main 移动源码：flutter analyze lib test exit 0，无问题；完整 Flutter 4443 passed / 9 skipped exit 0；认证恢复专项 41 passed exit 0。
- 新增本轮内容不改 Flutter、Business API/Worker 实现，复用 f820d704 集成门禁与 2179 相同 API/Worker 输入的完整证据（2905 passed /75 skipped）。不重复声称本轮运行这些全量测试。
- 完整 verify.ps1 前轮真实 exit 1：隔离树缺 .env。未声称通过。没有生产部署，历史生产证据保持历史属性。

## 67 项逐文件处理

| 路径 | 原状态 | 对 f820 | 处理 |
| --- | --- | --- | --- |
| apps/mobile_flutter/lib/core/installation_startup_gate.dart | M | identical | 功能已吸收，归档旧副本，保留远端实现 |
| apps/mobile_flutter/lib/features/matrix/matrix_client_factory.dart | M | different | 功能已吸收，归档旧副本，保留远端实现 |
| apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart | M | different | 功能已吸收，归档旧副本，保留远端实现 |
| apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart | M | different | 功能已吸收，归档旧副本，保留远端实现 |
| apps/mobile_flutter/lib/features/matrix/matrix_user_avatar.dart | M | identical | 功能已吸收，归档旧副本，保留远端实现 |
| apps/mobile_flutter/test/core/installation_startup_gate_test.dart | M | identical | 功能已吸收，归档旧副本，保留远端实现 |
| apps/mobile_flutter/test/features/matrix/matrix_client_factory_test.dart | M | different | 功能已吸收，归档旧副本，保留远端实现 |
| apps/mobile_flutter/test/features/matrix/matrix_home_identity_pending_test.dart | M | identical | 功能已吸收，归档旧副本，保留远端实现 |
| apps/mobile_flutter/test/features/matrix/matrix_home_room_delegation_test.dart | M | identical | 功能已吸收，归档旧副本，保留远端实现 |
| apps/mobile_flutter/test/features/matrix/matrix_home_scan_entry_test.dart | M | identical | 功能已吸收，归档旧副本，保留远端实现 |
| apps/mobile_flutter/test/features/matrix/matrix_home_snapshot_refresh_test.dart | M | different | 功能已吸收，归档旧副本，保留远端实现 |
| apps/mobile_flutter/test/performance/conversation_home_projection_test.dart | M | identical | 功能已吸收，归档旧副本，保留远端实现 |
| apps/mobile_flutter/third_party/matrix/CHATFLOW_PATCH.md | M | identical | 功能已吸收，归档旧副本，保留远端实现 |
| apps/mobile_flutter/third_party/matrix/lib/src/database/matrix_sdk_database.dart | M | identical | 功能已吸收，归档旧副本，保留远端实现 |
| docs/runbooks/admin-production-workflow.md | M | different | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/verification/2026-09-23-after-third-review-batch.md | M | different | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/workflow/current-state.md | M | different | 补历史文档/选择性合并，ADR冲突重编号 |
| frontend/download.html | M | different | 旧2172文案仅归档，保留2173 |
| frontend/home.html | M | different | 仅合入独立OTA断言/注释/cache key，保留2173 |
| frontend/src/admin-home.js | M | different | 旧2172文案仅归档，保留2173 |
| frontend/src/download-redirect.js | M | different | 仅合入独立OTA断言/注释/cache key，保留2173 |
| frontend/tests/download-redirect.test.mjs | M | different | 仅合入独立OTA断言/注释/cache key，保留2173 |
| frontend/tests/home-ios-download.test.mjs | M | different | 仅合入独立OTA断言/注释/cache key，保留2173 |
| apps/mobile_flutter/test/features/matrix/avatar_cold_start_test.dart | ?? | identical | 功能已吸收，归档旧副本，保留远端实现 |
| apps/mobile_flutter/test/features/matrix/cold_start_identity_test.dart | ?? | different | 功能已吸收，归档旧副本，保留远端实现 |
| apps/mobile_flutter/test/features/matrix/cold_start_preview_cache_test.dart | ?? | identical | 功能已吸收，归档旧副本，保留远端实现 |
| apps/mobile_flutter/test/features/matrix/cold_start_preview_persistence_test.dart | ?? | identical | 功能已吸收，归档旧副本，保留远端实现 |
| apps/mobile_flutter/test/performance/room_unrelated_sync_diagnostic_test.dart | ?? | different | 功能已吸收，归档旧副本，保留远端实现 |
| artifacts_list.json | ?? | absent | 临时数据仅忽略目录归档，禁止提交 |
| artifacts_tmp_wf.json | ?? | absent | 临时数据仅忽略目录归档，禁止提交 |
| docs/adr/0080-chat-e2ee-retirement.md | ?? | absent | 未批准提案，仅私有归档，未实施 |
| docs/adr/0085-public-group-announcements.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/runbooks/refresh-release-guards.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/superpowers/plans/2026-09-23-e2ee-retirement-plan.md | ?? | absent | 未批准提案，仅私有归档，未实施 |
| docs/superpowers/plans/2026-09-23-feedback-2165.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/superpowers/plans/2026-09-24-announcement-wallet-support.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/superpowers/plans/2026-09-24-cold-start-cache.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/superpowers/plans/2026-09-24-online-room-refresh.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/superpowers/plans/2026-09-24-refresh-release-guards.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/superpowers/plans/2026-09-24-refresh-restore.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/superpowers/specs/2026-09-24-online-room-refresh-design.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/superpowers/specs/2026-09-24-refresh-release-guards-design.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/verification/2026-09-24-announcement-wallet-support.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/verification/2026-09-24-cold-start-cache.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/verification/2026-09-24-feedback-2165.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/verification/2026-09-24-moments-auth-incident.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/verification/2026-09-24-online-room-refresh.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/verification/2026-09-24-online-room-transition-audit.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/verification/2026-09-24-refresh-release-guards.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/verification/2026-09-24-refresh-restore.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/verification/2026-09-24-regional-network-assessment.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/workflow/tasks/2026-09-23-feedback-2165.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/workflow/tasks/2026-09-24-announcement-wallet-support.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/workflow/tasks/2026-09-24-cold-start-cache.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/workflow/tasks/2026-09-24-moments-auth-incident.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/workflow/tasks/2026-09-24-online-room-refresh.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/workflow/tasks/2026-09-24-online-room-transition-audit.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/workflow/tasks/2026-09-24-refresh-release-guards.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| docs/workflow/tasks/2026-09-24-regional-network-assessment.md | ?? | absent | 补历史文档/选择性合并，ADR冲突重编号 |
| headers.txt | ?? | absent | 临时数据仅忽略目录归档，禁止提交 |
| scripts/business_refresh_image_probe.py | ?? | absent | 补合并已批准续期守卫 |
| scripts/business_release_guard.py | ?? | absent | 补合并已批准续期守卫 |
| scripts/install_refresh_watchdog.py | ?? | absent | 补合并已批准续期守卫 |
| scripts/refresh_alert_email.py | ?? | absent | 补合并已批准续期守卫 |
| scripts/refresh_watchdog.py | ?? | absent | 补合并已批准续期守卫 |
| tests/infra/test_refresh_release_guards.py | ?? | absent | 补合并已批准续期守卫 |
| wf_runs.json | ?? | absent | 临时数据仅忽略目录归档，禁止提交 |

## 本轮最终验收结果

infra 172 passed，21.29s，exit 0；frontend 311 passed，exit 0；Repository policy / Deployment policy exit 0。日志位于本集成树忽略目录 docs/verification/artifacts/2026-09-26/main-wip-policy-audit/。独立规格后质量安全审查：无阻断项、无真实凭证。

## 已执行结果与并发边界

- 补集成提交 d1c8879637de805ae270502906bd5c7b325aa32b 已普通快进推送 GitHub main，push exit 0。
- 8 个本地 codex 分支全部删除，named 历史工作树先在原 tip detach，文件与证据保持。2 个远端 codex 分支删除成功，push exit 0。本地只保留 main，远端只保留 main；最终远端回读由本轮结尾验收日志记录。
- 原 67 项清理前再次验证原文件及归档 SHA256。23 tracked 逐文件恢复到旧 HEAD，44 untracked 原路径副本移除；完整归档保留，没有删除唯一文件。
- 清理时出现另一批实时新增的诊断持久化/网络错误源码与测试，涉及 chat_diagnostics_spool_store、main.dart、客户端和接收端。本次未批准其完成状态、未测试、未合并、未删除。继续写入迹象已观察到，因此原 main 工作树仍停在 b9eca8a4 且有新增 WIP，没有强制更新或宣称它干净。
- 新增 WIP 单独快照位于原根忽略目录 docs/verification/artifacts/2026-09-26/concurrent-diagnostics-wip/，包含文件、SHA256清单与tracked.patch。它与原67归档分开，保留后续作者工作。其他历史 detached 工作树也未删除。
- 下一可执行步骤：确认并发作者停止/隔离其工作，再以 b9eca8a4 为共同基线增量迁移该 WIP 到新 main，保留统一trace/生命周期并重新测试。不能整文件覆盖新 main，会丢已有诊断实现。用户关于是否有并发作者的澄清仍待答复。
- 此次没有重新运行完整 verify.ps1，复用上一任务 exit 1 的真实缺配置结果与同输入独立门禁；本轮完整 infra/frontend 和独立两级审查均通过。没有生产/API/SMTP/设备写入。
