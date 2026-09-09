# 钱包诊断日志实施与发布证据

日期：2026-09-08。用户已明确批准日志设计及实施。仅增加可观测性与日志配置，没有执行钱包恢复或改变资金判断。

## 实现

- 独立 TRON 包可使用的标准库 JSON logger，支持 ERROR/WARNING/INFO/DEBUG，默认 INFO；明确恢复被迁移 fileConfig 禁用的 logger。
- 请求错误区分 HTTP 429、4xx、5xx、连接/读/写/池超时、连接/协议错误和 JSON 解析失败；保留固定阶段、路由模板、请求 ID、耗时和应用内栈帧，不保留异常消息、请求正文、响应正文、凭据、完整地址或金额。
- 观察轮次 trace_id 关联请求和已提交的 run_id/observation_id。验证失败按固定映射保留原因，不改变原 SNAPSHOT_FAILED 等业务错误码。
- 数据源日志包含所有 failed_conditions、区块/心跳/观察年龄、时效阈值及 fresh_until_ms。复现 199543ms > 180000ms 时同时显示 SOLID_HEAD_STALE、SOURCE_RUN_ERROR、RECONCILIATION_PENDING。
- 事故/告警事件在事务提交后记录 incident_id、event_id、generation 和 action。保存点回滚、父保存点回滚、会话关闭和会话复用不会产生虚假成功日志。
- API、Worker、观察器日志轮转为每容器 20m × 10。提供服务器受限归档脚本和明确执行的 14 天归档清理命令；没有创建定时任务。

## 测试与审查

原始失败证据及最终输出位于 [本次工件目录](artifacts/2026-09-08/wallet-diagnostics/)。

- red.txt：新诊断模块尚不存在。
- red-source.txt：缺少观察失败分类与具体时效诊断。
- red-archive.txt：缺少脱敏归档工具。
- red-disabled.txt：迁移日志配置禁用 logger 后无输出；已修复并回归。
- red-review.txt：缺少固定路由和全部失败条件。
- red-transaction-lifecycle.txt：父保存点回滚/关闭会话后的虚假成功日志；已修复并回归。
- red-source-link.txt：缺少 run_id 与 fresh_until_ms 关联。
- green-final.txt：最终相关测试 228 passed、1 skipped；跳过为未配置 PostgreSQL 的集成路径。Starlette/httpx 弃用警告来自现有测试依赖。
- verify-final.txt：仓库验证中后端 API/Worker 1363 passed、31 skipped、1 warning；该运行开始后的小范围审查修正由上述最终聚焦回归覆盖。初次完整运行的 11 个新增日志测试失败均已定位到 fileConfig 禁用 logger，非资金回归失败。
- 单独收集部分既有路由测试曾遇到 SQLAlchemy 元数据缺少关联表的 fixture 导入顺序问题；采用项目完整收集范围后通过，最终 228 项范围也包含这些路由测试，未为此改动产品模型。
- 独立审查按规格符合性、质量/安全顺序执行；发现的事务生命周期 P2 已修复，并独立复现三层嵌套提交、父保存点回滚及会话复用通过。最终无未解决 P0/P1 或发布阻断项。

## 发布

2026-09-08 10:33 UTC（香港 18:33）发布至原服务器。发布目录 `/opt/starchat/releases/wallet-diagnostics-20260908/`。

仅将本轮前基线与本轮源码的唯一上下文差异应用到服务器正在使用的源码副本，不使用整个本地工作区覆盖服务器。原部署有多层 Compose 叠加，已保留全部原列表，并在末尾增加受限发布覆盖文件。敏感环境与 Docker inspect 仅保存服务器 0700/0600 发布目录，不进入本地工件。

- API：`sha256:8b4620593465dedd178e3acf9a4d04c641424858318626b82c771623e2884678`。
- Worker：`sha256:239f08de81d9f5105c7d687fac2d3659afc47eb9dea2e33825a5710fbc2d9a87`。
- 观察器保留原固定运行镜像 `sha256:961c3a0e1b9a32f40455ed1fe14cfa7e4a28ef9b6c2f139cb792108ca350b276`，切换到已验证的新只读代码目录；观察数据库挂载不变。

两个候选业务镜像在 --network none 环境用 MockTransport 验证 429 分类和敏感响应排除。观察器以原 UID 10001 在断网容器中验证导入和代码可读性。

发布配置渲染逐字段核对实际容器环境和数据挂载，仅增加 WALLET_DIAGNOSTIC_LOG_LEVEL=INFO、日志轮转和指定代码/镜像更新。发布脚本检查原容器 ID，防止覆盖并行发布。

## 线上验收

[live-verified.json](artifacts/2026-09-08/wallet-diagnostics/live-verified.json) 为脱敏线上证据：

- API、Worker、观察器全部 healthy。
- 运行文件 SHA256：API 9 个、Worker 10 个、观察器 4 个，共 23 个全部匹配发布清单。
- 真实进程已输出 service_starting、service_started、source_health、maintenance_state、scan_completed、scan_state。
- 三个容器运行态 LogConfig 均为 json-file、20m × 10。
- 10:33:53 UTC 钱包仍 withdrawals_paused=true，pause_reason=MANUAL_SOURCE_UNHEALTHY；监控 last_error_code=MANUAL_WALLET_PAUSED。本次未调用恢复、事故确认、复核或结案接口。
- 10:34:55 UTC 归档实际写入 API 2 条、Worker 8 条、观察器 6 条新诊断，目录 0700、文件 0600 校验通过。升级前没有 schema-v1 日志，因此首次归档为 0 条，不虚构旧故障细节。
- 观察器随后没有新的 ERROR/WARNING；Worker WAITING 表示原钱包暂停仍在生效。

回滚配置渲染通过，原镜像存在。`python3 deploy_release.py --rollback` 可恢复原应用镜像和观察器代码挂载，同时保留新增日志容量上限，不回滚数据或资金状态。未在生产为演练主动回滚健康发布。

钱包恢复步骤见 [恢复运行手册](../runbooks/wallet-incident-recovery.md)，日志使用见 [TRON 观察器运行手册](../runbooks/tron-watch-only.md)。

## 全仓验证状态

scripts/verify.ps1 最终退出成功，输出 `Verification: PASS`。基础设施 62 passed、Getui 28 passed、Matrix Bot 9 passed、后端 API/Worker 1363 passed/31 skipped、移动端边界 66 passed。UI 契约（17 components/330 screens）、186 个 Python 文件 AST、迁移离线生成、OpenAPI 与 Docker Compose 检查全部通过。

移动端隐私检查扫描大量历史验证工件，耗时 501.74 秒；没有跳过该检查。环境依赖的 31 项测试跳过及现有 Pydantic/Starlette 弃用警告已保留在原始输出，未通过修改依赖或测试规则掩盖。全仓运行后的小范围审查修正和 API 启动日志由最终 228 项聚焦回归及线上源码/健康验收覆盖。
