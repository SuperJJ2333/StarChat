# 钱包链上诊断日志设计

状态：用户已确认；2026-09-08 已实施并部署，证据见 docs/verification/2026-09-08-wallet-diagnostic-logging.md。
日期：2026-09-08。
范围：TRON 观察器、人工钱包监控及对应 Worker 的诊断日志；提供现有钱包恢复操作说明。

## 问题与依据

事件 `b547fb99-dc66-4ab0-b306-6043ca044b56` 是事故 `3f86ae92-038c-4816-b40d-b92a887bbb6e` 的升级通知。服务器核查证实一次 SNAPSHOT_FAILED 后固化区块数据超过有效期，触发保护暂停；快照失败的底层原因没有保留下来。

当前 reader.py 的 _request 把 HTTPError 和 JSON 解析失败统一转成 TronReadError('TRON request failed')，且删除异常链；observer.py 再把非 ObservationError 统一记为 SNAPSHOT_FAILED。cli.py 输出脱敏状态摘要。Docker 已有 5 MiB × 3 的轮转，事故、审计、Outbox 也已有持久化记录，但这些不能替代请求级诊断。

## 方案选择

1. 推荐：补充统一的结构化诊断工具，接入现有 Docker 日志、观察器与钱包监控，保留原业务错误码和告警流程。改动集中，能直接追踪本次问题。
2. 仅打印异常堆栈：实现简单，但 HTTP 异常消息可能包含完整地址、查询参数和凭据，且不能完整关联告警，不采用。
3. 部署集中日志平台和后台搜索页面：跨服务检索更方便，但引入额外服务、权限和存储运维；本次先交付方案 1，集中平台不作为这次交付前提。

## 日志级别

- ERROR：快照/请求失败、监控执行失败、已触发事故阻断、告警投递失败。
- WARNING：证据未就绪、观察延迟、短暂采样不稳定、等待核对；重复状态按原因聚合，状态变化立即记录。
- INFO：服务启动、扫描摘要、来源恢复、事故创建/升级/复核/结案以及资金控制操作的已提交结果。
- DEBUG：每个请求阶段的开始/结束、耗时、分页数量、检查条件及阈值。用户所说 DEBUGGER 对应此标准级别。

默认 INFO；通过受保护环境配置临时启用本次组件的 DEBUG，不能同时打开 httpx/httpcore 等第三方库的原始详细请求日志。非法级别使配置检查失败。

## 日志结构及关联

每行 JSON 包含 UTC 时间、level、service、component、event、reason_code、trace_id、duration_ms 和 schema_version。

一个观察轮次共用 trace_id，请求再生成 request_id。扫描日志记录提交成功后的 run_id、observation_id、checkpoint_ms、solid_block、solid_timestamp_ms。钱包监控日志通过观察编号关联上游；输出 heartbeat_age_ms、observation_age_ms、solid_head_age_ms、freshness_limit_ms、fresh_until_ms 和 pending_age_ms，并明确哪些条件失败。

阻断诊断列出实际原因，例如 SOURCE_RUN_ERROR、SOLID_HEAD_STALE、OBSERVATION_STALE、CLOCK_AHEAD、RECONCILIATION_PENDING、BALANCE_UNSTABLE、BASELINE_NOT_REACHED。对外 MANUAL_SOURCE_UNHEALTHY 等业务错误码保持现有契约。

事故和 Outbox 日志关联 incident_id、event_id、generation、monitor trace_id。只在事务提交后宣称事故创建、恢复或投递成功；回滚只记录尝试失败，避免出现实际上未提交的“成功”日志。不向原有财务表或观察数据库增加日志字段，不修改余额、暂停或恢复条件。

## 保留底层原因

在异常被归一化前提取类型安全的诊断字段：固定请求阶段（固化区块、余额查询、历史列表、交易收据）、固定路由模板、HTTP 状态码、耗时、扫描预算、超时类别、异常类别。

分别覆盖 ConnectTimeout、ReadTimeout、WriteTimeout、PoolTimeout、连接/协议异常、HTTP 429、HTTP 4xx/5xx、非法 JSON、上游错误标识、扫描总时限、分页/交易数上限及固化区块回退。对未知异常保存限长的应用内栈帧（模块/函数/行号），不保存源代码行、局部变量或原始异常消息。无法确认的上游内部原因仍如实标记 UNKNOWN，不能由日志推断不存在的根因。

日志字段采取白名单和长度/类型约束。路由采用 /v1/accounts/{address}/transactions/trc20 模板；不输出真实地址、完整请求 URL、参数、请求/响应正文、请求头、Token、API Key、密码、余额、金额和聊天数据。DEBUG 同样遵守此规则。

## 存储、运行与可靠性

输出标准错误流 JSON，由 Docker json-file 采集。为本次三个组件规划每容器 20 MiB × 10 的轮转上限；这是容量上限，不承诺固定保留天数。部署重建容器前，将这几个组件的诊断日志导出到服务器受限目录 /opt/starchat/diagnostic-archives/，目录 0700、文件 0600，按部署批次及服务命名；运行手册给出按事件/时间检索和删除超过 14 天归档的方法。不导出完整环境、观察数据库或财务数据库。

轮转和归档均不改变原服务挂载及 Compose 叠加顺序。发生写日志失败时不得改变资金判断或引入金融事务回滚；诊断工具使用受限固定兜底信息。状态摘要 status.json 与观察库原结构继续兼容现有消费者。

## 文件边界

实施时由同一执行者顺序修改以下文件，开始前核对现有未提交变更：

- 新建 services/business-api/app/integrations/tron/diagnostics.py：可独立以 tron 包导入的标准库日志工具，无业务库依赖。
- services/business-api/app/integrations/tron/reader.py：请求分类和阶段诊断。
- services/business-api/app/integrations/tron/observer.py、cli.py：轮次关联、提交后结果、运行配置。
- services/business-api/app/integrations/tron/funding_source.py：可重用的健康检查诊断事实，保持已有接受/拒绝条件。
- services/business-api/app/modules/wallet/manual_reserve_monitor.py：实际阻断条件、观察编号和监控轮次关联。
- services/business-api/app/modules/wallet/incidents.py：仅补充事务结果日志关联，不更改事故状态机。
- services/business-worker/app/main.py、app/tasks/manual_wallet.py：配置和任务边界。
- docker-compose.tron-watch.yml、docker-compose.wallet-manual.yml：日志容量和配置。
- tests/business_api/tron/、tests/business_api/wallet/、tests/business_worker/、tests/infra/：新增诊断测试与现有契约回归。
- docs/runbooks/tron-watch-only.md、docs/runbooks/wallet-incident-recovery.md：日志检索、归档、DEBUG 和恢复说明。
- docs/verification/：脱敏 red/green、回归、发布及回滚验证证据。

## 验收

先写失败测试，确认日志缺失是预期失败原因，再最小实现。重点用真实 httpx.MockTransport 构造 429、503、超时、坏 JSON，证明诊断分类正确且底层异常里的合成密码、地址、Header、响应内容不会出现在任何级别日志里。验证未知异常栈帧裁剪、字段长度、跨轮次隔离及日志工具故障隔离。

复现本次时间线：采样失败、固化区块年龄 199.5 秒超过 180 秒、形成 P0、来源恢复而保护暂停仍存在。日志必须同时解释失败请求阶段和后续超时触发条件，并能从事故 ID 追到观察轮次。新增日志不得推进失败扫描水位或修改健康判定。事务回滚不得留下“已成功”日志。默认 INFO 不输出 DEBUG；配置 DEBUG 后输出相同脱敏标准的阶段日志。

运行聚焦测试及 scripts/verify.ps1，先做规格符合性检查，再做质量/安全检查。发布需核对实际容器源代码和轮转配置，并保留原镜像/挂载/配置供回滚。日志上线与钱包恢复分开验收；增加日志不能保证上游不再故障，但必须消除已知异常分类被吞掉的问题。

## 当前交付状态

已完成现状定位、实现、独立审查及日志上线。钱包仍保留原保护性暂停，恢复步骤由管理员另行执行。全仓验证状态与实际测试结果以验证记录为准。
