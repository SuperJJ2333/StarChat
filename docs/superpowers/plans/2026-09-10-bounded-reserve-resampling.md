# 有界过期快照重采样实施计划

> 使用 subagent-driven-development / executing-plans，逐项测试先行执行。

状态：按用户已确认的方案 A 修订版执行，依据 ADR-0061。根协调者保留其他工作区改动，不提交混合变更。

**目标：** 消除短暂快照更新间隙造成的长期人工暂停，同时保持过期证据不可消费和告警调度可用。

**结构：** 独立读取分类包装，不改 ReserveCut/digest；监控器有界轮询并先失效储备；后台单任务协调器隔离阻塞等待。

## Task 1：源分类与预算（源实现代理拥有）

- 文件：funding_source.py、新 test_reserve_cut_sample.py。
- 先失败测试同一SQLite事务的过期单因、ERROR/差异/未核实/未来时间不合格，正常 ReserveCut 摘要不变、只读、剩余预算。
- 实现 frozen ReserveCutSample(cut, age_expired_only)，read_reserve_sample(timeout_seconds=...)；保留旧 read_reserve_cut 接口和所有资金证据格式。
- focused tests red/green，返回精确接口供根协调者接入。

## Task 2：后台协调器（调度实现代理拥有）

- 文件：新 worker app/tasks/reserve_monitor_runner.py、新 test_reserve_monitor_runner.py；后续将 main.py、manual_wallet.py、config.py、Compose 和接线测试一并明确交由该代理，避免并发编辑。
- 单线程 single-flight：run_once 消费一次已完成结果或调度后返回 WAITING；ensure_running 只调度不消费结果。保留结果至主维护任务消费。close 不再允许启动并等待线程退出。
- 先测试阻塞扫描不阻塞调用方、两个调用点不重入、结果不复用、异常可重试、关闭与资源顺序。

## Task 3：监控器与接线（根协调者拥有）

- 文件：manual_reserve_monitor.py、manual_source_resample.py、diagnostics.py、新 monitor wait tests。领域审查期间将 monitor 和独立 preflight 测试交由领域代理修复，接线文件由 Task 2 代理独占。
- 构造预算默认0，worker显式60；HTTP保留原分支。适配器分类与摘要同时合格才能等待；等待前失效储备、保留暂停、写心跳；重新采集预期版本；单调预算不重置、新ID和全量校验、超时/故障沿用阻断。
- 接线两个后台监控入口共享协调器；手动维护消费结果；退出先join再关闭runtime。
- 先失败测试所有恢复/阻断/资金准入/时钟/锁与调度回归，再最小实现。

## Task 4：复核、集成、文档（根协调者拥有）

- 更新 wallet-incident-recovery.md、ADR和 docs/verification/ 证据；不操作当前事故状态。
- 先领域后质量安全复核，修复发现；隔离真实SQLite/PostgreSQL锁与事务验证。
- 运行相关 wallet/source/worker tests，再 scripts/verify.ps1；报告通过、跳过及真实集成范围，不把静态测试当生产修复证明。

## 执行进展

Task 1–4 已完成；领域审查发现的等待前业务异常与暂停归属检查已补齐。真实 SQLite 适配器测试、PostgreSQL 锁/资金版本竞争集成、后台调度及部署配置回归通过，质量安全复核及全仓库门禁通过。结果统一记录在 docs/verification/2026-09-10-bounded-reserve-resampling.md。本次未部署生产或操作当前事故恢复。

## Task 5：用户追加授权的生产部署

用户随后明确要求依 app-release-deployment.md 部署。根协调者拥有发布工件及 runbook/验证文档；代理只负责只读时钟核查、发布脚本审查与离线故障测试。

- 从当前 API/Worker 镜像、实际模块导入路径和各自 Compose 层建立基线；仅覆盖修复文件，保留 API 已上线 payment_pin 配置，禁止整库覆盖。
- SHA256 校验上传；保存服务器受限配置、数据库备份，断网恢复演练；候选/回退均先创建不启动的临时容器，完整比对运行配置。
- 冻结原配置，worker 仅增加预算 60；停止旧 worker 后按 API、Worker 顺序切换，失败回退代码，不恢复数据库、不改资金控制。
- 核验新镜像/代码摘要、健康端点、至少数个监控周期、事故与控制状态、无关容器未变化；记录时间偏差为独立未解决项，不直接回拨主机。
- 实测生产 schema 为 0059_chat_payment_pin，原事故已 RESOLVED、withdrawals_paused=false；不复用历史报告作为发布基线。

Task 5 已完成：候选/回退配置、备份恢复演练和发布故障测试通过，API/Worker 切换健康，运行代码摘要、监控成功心跳与公网 JSON/鉴权检查通过。生产结果见 docs/verification/2026-09-10-reserve-resampling-production.md；时间同步问题独立保留。
