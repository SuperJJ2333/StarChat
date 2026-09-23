# 2026-09-23 已核验充值客服直发专项验证

候选基线 `1baaf36eaa02f4ee903f09591b694cac1a90695b`，工作树 `.worktrees/staff-workbench-ui-20260923`；保留既有工作台/UI/用户只读投影。用户已明确授权该充值审批规则和部署，子任务只实现验证，未操作生产资金、未部署、未提交。

设计：[ADR-0084](../adr/0084-verified-recharge-direct-settlement.md)；[计划](../superpowers/plans/2026-09-23-direct-recharge-settlement.md)。

## 红绿证据

环境 Windows、PowerShell 7、Python 3.12.10（`py -3.12`）；`PYTHONPATH=services/business-api;services/business-worker/app;.`，UTF8。

| 命令/检查 | 真实结果 | 说明 |
| --- | --- | --- |
| `python -m pytest tests/business_api/wallet/test_support_recharge_direct_settlement.py -q` | exit 1，collection error | 系统 Python 缺 coincurve；未安装依赖，改用仓库 verify 的 Python 3.12 |
| `py -3.12 -m pytest tests/business_api/wallet/test_support_recharge_direct_settlement.py -q`（实现前） | exit 1，3 failed / 6 passed，3.56s | 两项被 PENDING_APPROVAL 拦住，专用接口缺失；符合缺失行为 |
| 同上（中间） | exit 1，2 failed / 7 passed，3.51s | 执行成功，旧登记强制 reviewer；补充有消费回执及绑定的专用登记兼容 |
| `py -3.12 -m pytest tests/business_api/wallet/test_support_recharge_direct_settlement.py tests/business_api/wallet/test_support_order_settlement_integration.py tests/business_api/wallet/test_support_settlement_boundary_review.py tests/business_api/wallet/test_support_recharge_receipts.py tests/business_api/recharge -q` | exit 0，103 passed / 4 skipped，108.68s | 新无审批直发/并发及全部相邻充值；4项为条件PG未配置，不是通过 |
| `py -3.12 -m pytest tests/business_api/ledger -q` | exit 0，17 passed，21.17s | 普通审批/账本守卫回归 |
| direct 测试 `-k generic_submit`（补充实现前） | exit 1，1 failed / 9 deselected | 通用提交确实允许伪造 support-recharge:；先红后封禁保留命名空间 |
| `py -3.12 -m pytest tests/business_api/wallet/test_support_recharge_direct_settlement.py tests/business_api/ledger/test_adjustments.py -q`，配置独立PG | exit 0，15 passed，4.75s | 最新补充含命名空间禁止、真实PG及普通调整审批，0 skip |
| direct 测试 `-k registration_crash`（独立复审补充） | exit 0，1 passed / 11 deselected，1.45s | 无reviewer直发提交后模拟登记宕机，worker恢复且只有一笔账 |
| direct 测试 `-k real_http`（主任务补充） | exit 0，1 passed / 12 deselected，2.09s | 真实激活/管理会话与真实路由；字段未过滤；APP403/禁用拒绝/正常直发成功 |
| `git diff --check` | exit 0 | Git 提示现有 CRLF 正规化；无空白错误 |

完整输出在本任务工具 transcript（主要 chunk a1899d、19948b、575d39、a812f4、d3cf50、7eec5c、4e1929、deeaea）。上述表逐项抄录实际退出码；不是合成原始日志。冻结输入 SHA256 及依赖锁见 [input-sha256.json](artifacts/2026-09-23/direct-recharge-settlement/input-sha256.json)。完整专项后仅规范测试 os import，并新增独立复审建议的登记宕机恢复回归；生产源码未再改变。

## PostgreSQL

复用本地隔离测试容器 starchat-support-review-pg，创建本任务独立数据库 direct_recharge_20260923；新随机 direct_ schema 先从零迁移唯一 head 再运行真实凭证/账本服务。没有清空或修改既有 support_review 数据库。连接口令只经 docker inspect 进入测试进程环境，不写日志或仓库。

真实 PostgreSQL 用例先在资金已写入但最终提交前撤销授权，验证账本为0、调整仍SUBMITTED、回执仍RESERVED；之后两个独立session并发直发，均得到CREDITED，账本只有一笔71.23点钻、回执CONSUMED、reviewer字段为空。该库/schema保留供审查。SQLite文件数据库也有两session并发覆盖。

## 实现与边界

- 公开财务 `execute_support_recharge` 只认有托管订单、专用命名空间、RECHARGE_CREDIT 原因及当前认领授权的绑定。通用 `execute` 仍审批；通用 `submit` 禁止占用专用命名空间。
- 保留 payment_verified、真实付款回执/归属、最终确认、超时核对、交易级全局锁、服务端账本幂等键、消费回执和审计/Outbox。
- prepare仍冻结结算；UI可连续prepare→execute，已有绑定必须展示冻结汇率/金额。旧批准调整及已执行待登记不重复发币。
- 新直发不伪造审批；reviewer为空，另写 recharge.direct_settlement_executed 审计/Outbox。
- 未改schema、API路由、OpenAPI、main或前端；主任务负责响应文档/UI和增量部署。

## 审查与下一步

主任务先做独立领域/规格审查，再质量安全审查；重点检查专用资格不可扩大、提交前撤权、历史已执行凭证恢复、防二次发币以及UI冻结金额展示。主任务上一轮完整verify输入的旧审批源码不覆盖本次变更，须结合本专项按影响评估复用，不可将旧全量标成本次全量。

回退不能删除资金记录或无审批直发审计；需保留新执行记录登记兼容。生产未部署；服务器实际基线/隔离备份与发布由主任务执行。

HTTP补测初次断言APP应401而实际403，属于测试预期过严；已确认返回PERMISSION_DENIED，修正断言为403。首次TestClient出现上游弃用warning，改用项目既有AsyncClient/ASGITransport；最终无warning。主任务已确认规格及独立安全审查通过；部署证据仍由主任务记录。4个生产源码保持冻结，最后追加仅测试/文档。

后续交付状态：本批已完成生产发布及Mi6 2163安装，上文未发布/未安装为实现阶段记录；以[最终发布记录](2026-09-23-staff-direct-release.md)为准。
