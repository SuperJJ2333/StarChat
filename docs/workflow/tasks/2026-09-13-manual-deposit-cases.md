# 窗口外充值人工补录

授权：用户明确要求补齐人工补录、用户归属、审批、幂等及审计；不自动部署或实际加款。Astra主审，显式gpt-5.6-terra执行，当前工作区，原有变更保留。
状态：M1–M4本地实现、领域/质量安全复核与自动化验收完成；尚未发布。计划[执行计划](../../superpowers/plans/2026-09-13-manual-deposit-cases.md)，决策[ADR0069](../../adr/0069-manual-deposit-cases.md)。
证据目录：docs/verification/artifacts/2026-09-13/manual-deposit-cases/，已保存baseline.patch；精确阶段起止继续写工具日志，主动耗时未知。
下一步：若后续授权生产发布，按运行手册发布迁移及前后端，再在后台按流程核实并处理实际交易；当前任务不包含生产操作。保留原5分钟普通流程，第二笔使用独立case而非同一订单重复入账。
模型：当前本机配置model=gpt-6-astra，无读取到的自定义agent覆盖；spawn_agent已明确model=gpt-5.6-terra并返回late_deposit_backend，未静默替换。

当前HEAD：c5cd589c799c52557c469d4a225c721292b1fdcd；当前工作区不回退其他任务。两执行者：late_deposit_backend独占后端/API/迁移/后端测试，late_deposit_ui独占前端及前端测试。
验证环境：主线程新建隔离PostgreSQL18.3实例，仅127.0.0.1:55469，synthetic数据库manual_deposit_test；无生产配置或秘密。旧PG充值修复3项通过（2.71秒，pg-old-repair-baseline-venv.log）。裸python实际为3.11且缺coincurve，首次收集失败已保留；后端测试统一用本仓.venv/Scripts/python.exe 3.12.10/pytest8.4.2。实例数据仅位于本任务artifacts，最终停止并清理该测试数据目录，保留日志。
阶段：05:39+08创建计划/基线；后端2项目标缺失红测（模块不存在、head未升级）已复现，随后两项设计评审通过并放行完整业务红绿实施。下一步主线程审M2实际行为用例与PG约束，前端与后端冻结响应契约。

06:00–06:14+08主线程实际复核源码/diff、资金调用链与浏览器合成流程。审批首次响应、幂等回放、锁顺序、事务末端校验和浏览器恢复缺陷已逐项退回，不以初稿报告作为验收。续派manual_backend_finish与manual_pg_constraints均显式gpt-5.6-terra，旧代理停止；同时最多两个执行者。

主线程证据：前端192通过（astra-frontend-full.log），严格布尔7通过（astra-strict-confirmation.log），真实PG迁移/约束与旧充值修复7通过（astra-pg-migration-old-repair.log），独立人工补录/并发/新旧完整HTTP流程21通过（astra-manual-and-http.log），OpenAPI check通过。具体日志均在本任务artifacts。

06:12:19+08综合verify首轮开始，Infra测试3失败/138通过：0066预检需要新表，旧测试fixture未注册repair_models；失败日志与退出码保留。执行者仅修fixture及新增schema缺失断言，Infra+release baseline145通过。06:14:45+08主线程启动综合verify第二轮，结果待记录。

并行工作区事实：对前轮760个Dart输入比对，6个其他任务文件发生变化，pubspec.lock未变；详见flutter-evidence-reuse.json。本任务没有改Flutter，不能把前轮2508通过称为当前全工作区Flutter通过。不得回退这些外部改动。

06:14–06:34+08第二轮综合门禁：Infra143、Getui28、MatrixBot9通过；业务API/Worker1931通过、1旧迁移测试失败、40可选跳过。Terra修正0041/0051测试边界，Astra审diff并复跑2通过。06:34后续门禁退出0：移动边界70、UI契约、导入/AST、迁移、OpenAPI与Compose通过。前端最终199通过；末端保护7通过。组合证据及未验证范围见[最终报告](../../verification/2026-09-13-manual-deposit-cases.md)，两轮原始非零退出日志不覆盖。

收尾：隔离PostgreSQL已确认停止。自动审批审查拒绝后续包含递归清理pg-data与停止预览进程的命令（blocked by policy）；命令未执行，合成pg-data和日志保留，本地4187预览可能仍运行。未尝试绕过该限制。

后续状态：2026-09-13用户另行授权后已部署生产（API119e6971/schema0066）；以上未部署描述为本地验收时的历史状态。见[生产发布证据](../../verification/2026-09-13-manual-deposit-production.md)。未实际补款。
