# R9a Outbox 临执行领取

目标与授权：IM remediation R9/A7-4，root 在独立复现后批准只修改 Worker.run_once 的预领方式。源码起点 `3b52c63290d5ee4ae5f207d5c53ccf87255586db`；前置复现提交 `70dee9dd6b200ce3675bb6798be135d6ae594680`。实现 owner `/root/fix_scheduler_r6`，树 `im-worker-lease-repro/StarChat`、分支 `codex/im-worker-lease-repro`。未部署。下一步：独立 domain/SPEC→QUALITY review，root 统一集成门禁；R9b active 超租约仍未实施。

## 改动与边界

Worker.run_once 仍先执行一次 maintenance/reap，然后顺序执行最多 limit 条，但每次仅在准备运行 handler 时 claim 一条。空队列立即退出，非正 limit 不领取，最终 heartbeat 和真实处理数量返回保留。每次 claim 继续使用 handled_topics 和现有 consumer 公共接口，重试、失败/DEAD、handover 过滤和幂等消息 ID 路径不变。没有新增 handler 并发，没有修改 OutboxConsumer、财务 handler、schema、历史 DEAD/PENDING 或业务公式。

整批预领会让尚未执行的尾部消息消耗五分钟租约。现在其他消费者可领取仍为 PENDING 的尾部消息，原 worker 不持有它的陈旧内存 message。该改动不解决单个 active handler 超五分钟、不提供 topic 公平或 exactly-once 保证；现有幂等仍必须保留。R9b 用例以 `strict=True, raises=AssertionError` 的明确 XFAIL 留在默认测试，若不再复现会 XPASS 使门禁失败，不能静默忘记。初始三个真实 RED 的原始日志也保留。

唯一相邻测试调整：test_reserve_monitor_runner.py 的 Consumer double 在 mark_succeeded 后排空。原 double 永远返回已成功同一个 event，新的多次 claim 会让它虚构 50 条消息；修正为真实 consumer 的终态语义，没有修改 reserve monitor 产品代码。

## RED → GREEN

- SQLite 原始确定性重入：单慢 301 秒 + tail，以及 49 个慢 handler × 7 秒 + tail（共50条），都得到 B→A 双 handler 调用、B attempt=2 和 A 的 OUTBOX_LOCK_MISMATCH。
- 新增独立 PostgreSQL 双消费者：A 在线程中进入真实慢 handler 并等待 Event，主测试将注入 clock 推进 301 秒，B 用独立 consumer/session 处理 fast tail，最后释放 A。旧实现同样真实 RED：B→A、锁归属错误；新实现只 B、attempt=1、A 正常结束。
- active 单 handler 301 秒独立故障仍 A-enter→B-enter→A-exit；crashed owner 在 299 秒拒绝重领、300 秒允许重领的控制继续通过。
- limit=2、handled_topics、maintenance/reap一次、heartbeat、空队列和非正 limit 有断言。

验证命令（PowerShell7 UTF8NoBOM，PYTHONUTF8=1/PYTHONIOENCODING=utf-8）：

`PYTHONPATH=services/business-api;services/business-worker/app;.`；原生 PostgreSQL gate 额外显式设置 `IM_WORKER_LEASE_TEST_DATABASE_URL=postgresql+psycopg://postgres@127.0.0.1:55479/im_worker_lease_r9a`。

1. `py -3.12 -m pytest tests/business_worker/test_worker_lease_window.py -vv --tb=short`：实施前 3 FAILED、5 PASSED、1 XFAILED，exit1；`jit-native-red.log` 包含 PG 行为失败，非环境失败。
2. `py -3.12 -m pytest tests/business_worker tests/business_api/test_outbox.py tests/business_api/test_outbox_handover.py -q -ra`：最终 **248 PASSED、1 strict XFAILED、0 skipped，exit0**，17.73秒；`jit-green-final.log`。
3. Black 检查新增专项测试；Ruff 检查 worker.py 与两份受影响测试；`git diff --check`（改动源码/文档）通过。Python3.12.10/pytest8.4.2/SQLAlchemy2.0.52；Black/Ruff 使用已安装 Python3.11 工具。

PG 使用本机 PostgreSQL18 新建的专属空 cluster，127.0.0.1:55479，测试数据库名称限定 im_worker_lease_*。仅创建 consumer 查询所需 OutboxEvent、handover notice/receipt/disposition 四个表；不导入生产配置。测试的 PostgreSQL 是真实数据库/连接/提交及两个执行线程，但注入时钟代替了墙钟五分钟等待，不是负载/吞吐/生产拓扑验收。测试后已 pg_ctl fast stop 成功，数据目录仅本任务 artifact 下且未入 Git。

## 首轮失败与修正证据

首次 broad run 是 245 PASS、3 FAIL、1 XFAIL，未当成成功：除上述不真实的 Consumer double 外，新 PG fixture 的 Base.metadata.create_all 被其他测试注册的无关模型扩大，遇到已有 red_packets Boolean DEFAULT 0 的 PostgreSQL DDL差异。fixture 改为只创建本场景实际查询表，没有修改金融 schema。另历史 support 回归依赖未跟踪的 `docs/verification/artifacts/2026-09-30/support-worker-compatibility/worker_probe.py`；从主仓复制且核对 SHA256 后运行，只调用其原有 SQLite 内存合成测试，不执行 probe.main/网络。该历史测试输入 hash 已进入 manifest，未将运行数据库或其他旧 artifact 入 Git。

完整 scripts/verify.ps1 已预检：脚本存在，本隔离树缺 .env，其配置渲染阶段依赖该输入，未为测试复制生产配置；root 仍负责最终共享候选全量门禁。这是明确未执行项，不据本次248项声称全仓完成。证据目录 `artifacts/2026-10-11/im-worker-lease-repro/`：输入 hash、PG版本/退出、原始 RED、最终 GREEN、preflight；日志仅合成数据。

阶段时间：13:13:06+08 记录第一轮广测完成前后环境；随后完成 fixture/double 修正与最终17.73秒回归、停止本任务 PG。每步绝对起止未完整采集，不编造精确总工时。后续版本身份以最终实现提交 SHA 及 `jit-input-hashes.json` 为准；本报告不代表部署或业务用户恢复已验收。