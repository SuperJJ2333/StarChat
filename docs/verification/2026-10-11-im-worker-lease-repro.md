# R9 A7-4 worker 租约隔离复现与最小修复设计

范围：按已批准 IM remediation R9/A7-4 与 root 2026-10-11 指派，仅只读生产源码、新增合成测试和设计；没有服务端访问、部署、生产数据读取/改动、DEAD 重放、schema 或金融公式修改。源码基线 `3b52c63290d5ee4ae5f207d5c53ccf87255586db`。独立树 `im-worker-lease-repro/StarChat`，分支 `codex/im-worker-lease-repro`；owner `/root/fix_scheduler_r6`。

当前所有权仅 `tests/business_worker/test_worker_lease_window.py`、本报告和专属 artifact。`services/business-worker/app/worker.py`、`services/business-api/app/core/outbox.py` 只读，尚未实施任何修复。下一步由 root 审核此复现/设计后明确修复边界；原生 storage 复审优先。

## 已证行为

测试真实导入 Worker/OutboxConsumer/OutboxPublisher，用 SQLite 内存数据库和注入时钟按确定顺序重入第二 worker。每次 claim transaction 已提交才执行 handler，因此不伪造消费实现，也不声称验证 PostgreSQL 并发锁或实际墙钟五分钟运行。事件只有 synthetic.* topic、空 payload，无账户/钱包/网络。

| 用例 | 观察 | 结果 |
| --- | --- | --- |
| 1 个慢 handler 301 秒 + 未开始 fast tail | A 在 t=0 已领取 tail；t=301 B 重领并执行 tail，attempt=2；A 返回后仍执行 RAM 中 tail，再报 OUTBOX_LOCK_MISMATCH | 预期尾部只由 B 执行，真实 RED |
| 49 个慢 handler 每个 7 秒 + 1 个 fast tail，limit=50 | 第 43 个慢 handler 后累计 301 秒即发生同样 B→A 双执行；整个批次 343 秒 | 真实 RED |
| 只有 1 个 active handler 跨 301 秒 | trace A-enter→B-enter→A-exit，A 最后锁归属错误 | 独立真实 RED；单条 claim 也不能消除 |
| crashed owner 租约恢复控制 | t=299 不可重领，t=300 可重领，attempt=2 并成功完成 | PASS，保留恢复语义 |

根因分开：`Worker.run_once` 一次 claim 最多 50 后逐条 handler；`OutboxConsumer.claim_batch` 对整批写同一个 locked_at。队列等待消耗了所有尾部事件的租约。旧 Worker 执行内存 message 前没有新的 ownership 断言，锁归属检查只在 handler 之后的 mark 操作中发生，所以失败的最终确认不能撤销已发生的副作用。单个 handler 本身过期是另一独立问题。测试只证明 handler 调用重复，不据此断言现有幂等业务已重复记账。

## 最小修复设计，尚未实施

1. **R9a 仅消除整批预领。** 保留 run_once 的最多 limit 个事件及顺序 handler 契约，但每次准备执行时调用现有 `claim_batch(limit=1, topics=handled_topics)`，完成该事件后再领取下一项，空队列立即退出。维护/reap 仍每次 run_once 一次，返回真实处理数量，heartbeat 语义单独核对。保留 consumer 的 topic、available_at、handover preparation、not_superseded、退避/DEAD 与同一 message.id 幂等路径。无需 schema、handler 并发或金融修改。预期上表前两个 RED 转绿；active RED 必须仍列为未解决，不能删除或改成“通过”。单个慢 topic 仍可占一个 worker，本步骤不宣称公平队列/无限慢 handler 已解决。
2. **R9b active lease 单独设计。** 先审计各 handler 的外部请求/数据库操作期限。可用当前 event ID + worker ID + attempt_count 作为有条件续租/确认的 fencing 输入，不必先新增 schema；生产默认 WORKER_ID 是固定字符串，因此只比 worker ID 不足以区分同名进程或下一次 claim。续租必须由独立短事务资源执行，严格拒绝过期/被接管的 token，不复活旧 ownership；续租线程不共享 handler 的 SQLAlchemy Session，数量与当前 active handler 有界。
3. **续租不能承诺任意阻塞场景 exactly-once。** 若进程暂停或数据库分区超过租约，旧同步外部调用不能被 Python observer timeout 可靠中止。还须保留 stable event ID 的实际 handler/provider 幂等、明确失去租约后的停止领取和迟到确认行为、按调用方可用能力设期限/隔离。不能在存活的旧调用仍可发副作用时仅设置超时并放开新调用。对无法 fencing 的外部副作用需明确 at-least-once 边界与单独验收，不降低 crash recovery。

建议后续文件 ownership：R9a 仅 `services/business-worker/app/worker.py` 与本测试/相邻 worker 测试；R9b 才考虑 `services/business-api/app/core/outbox.py` 的公共 renew/fenced completion 接口、对应 consumer 测试及必要 worker 接线。`outbox_handover.py`、所有财务 handler/schema、历史 DEAD/PENDING 不进入本次修改。扩展前先得到 root 的范围分配，规格→质量安全审查仍必需。

## 证据与边界

命令环境：PowerShell7 UTF8NoBOM，PYTHONUTF8=1、PYTHONIOENCODING=utf-8，PYTHONPATH=services/business-api;services/business-worker/app;.; Python3.12.10、pytest8.4.2、SQLAlchemy2.0.52。无 .env 导入，无网络。`input-hashes.json` 包含生产输入与测试 SHA256。

- `py -3.12 -m pytest tests/business_worker/test_worker_lease_window.py -vv --tb=short`：格式化前/后均 3 FAILED、1 PASSED，exit1，最终 `lease-red-final.log` / `lease-red-final-exit.txt`。
- `py -3.12 -m pytest tests/business_worker/test_worker.py tests/business_worker/test_worker_contract.py tests/business_api/test_outbox.py -q`：16 PASSED，exit0，`baseline-neighbors.log`。
- Black/Ruff 使用已安装的 Python3.11 工具，最终格式化/检查通过；Python3.12 未安装这两个工具，已明确改用现有工具，没有安装或改全局依赖。
- 此阶段交付是故障复现，三个 RED 有意保留且不是可部署绿色候选。没有运行整仓 verify/平台构建；没有产品源码变更。真正修复后需要相邻/集成门禁、PostgreSQL 双消费者覆盖、handover/idempotency/domain review。

阶段时间：2026-10-11 12:52:27+08 记录环境/fixture 前置；随后完成首次真实 RED、格式化并重跑固定输入，精确各阶段起止未全捕获，耗时不猜测。完整日志仅合成数据；所有 evidence 位于 `artifacts/2026-10-11/im-worker-lease-repro/`，无磁盘数据库夹具。