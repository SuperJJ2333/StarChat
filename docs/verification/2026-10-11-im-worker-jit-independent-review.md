# R9a 临执行领取：独立规格/领域与质量/安全审查

日期：2026-10-11，UTC+08；审查人：`backend_review`。审查树 `C:/Users/Administrator/.codex/worktrees/im-worker-lease-review/StarChat`，与实现 owner 的 `im-worker-lease-repro/StarChat` 分离。本审查只新增本报告和专属证据，不修改产品、不访问服务器、不部署。

## 冻结对象与结论

- 复现提交：`70dee9dd6b200ce3675bb6798be135d6ae594680`。
- 最小修复提交：`9e036261be1e3ba87d106c38737675c7f46b35fb`。
- 实现工作树 HEAD、审查工作树 HEAD 均为修复提交；实现树检查时无未提交修改。
- **第一阶段 SPEC/domain：PASS。第二阶段 QUALITY/security：PASS；没有阻断 R9a 的发现。** 结论仅为消除未开始事件的整批预领，不包含 active handler 超租约、topic 公平、吞吐上限或 exactly-once 保证。
- 可以进入 root 负责的候选镜像/实际导入路径/共享门禁与发布范围核验。本审查不是生产部署许可或部署后验收；不能把 R9b 的 strict XFAIL 宣称为已解决。

审查输入比对见 [review-manifest.json](artifacts/2026-10-11/im-worker-lease-independent-review/review-manifest.json)。比对采样时间为 13:23:14+08；阶段先后已执行，未完整采集开始/结束时间，不编造分阶段耗时。

## 第一阶段：规格与领域

1. **范围符合。** `services/business-worker/app/worker.py:149-192` 是唯一产品修改：maintenance/reap 各执行一次；循环最多处理原 `limit` 次；每次调用公开 consumer `claim_batch(limit=1, topics=handled_topics)`，当前 handler/finalization 完成后再领取下一项；空队列退出，非正 limit 不领取，最终 heartbeat 与处理次数返回保留。无 handler 并发、schema、消费者 SQL、金融公式或历史事件重放修改。
2. **租约根因与修复对应。** 原实现一次领取整批并把尾部 message 保留在内存；等前部慢 handler 完成后，即使尾部已经被别人重领，原 worker 仍可能调用它的 handler。R9a 不再提前持有尾部 message，因此尾部保持 PENDING/attempt=0，另一消费者首次领取后原 worker 会重新查询已提交状态，不再调用旧尾部对象。`tests/business_worker/test_worker_lease_window.py:78-135` 覆盖 1×301s 及 49×7s 两种时钟交错；不是生产耗时测量。
3. **消费者权限及领取条件保留。** 实际 `services/business-api/app/core/outbox.py:95-137` 仍在短事务中使用 `not_superseded`、available_at、PENDING/FAILED 或过期 PROCESSING、created_at/id 顺序、SKIP LOCKED、topic allowlist 与 handover preparation 限制。每次领取单条仍走该接口，未绕过任一过滤。mark_succeeded/failed/dead 仍经同文件 `208-224` 的 PROCESSING/worker_id 锁归属检查。
4. **历史 handover 与审计边界保留。** `core/outbox_handover.py:37-45` 只在 disposition、notice digest、SMTP receipt digest 均吻合时排除被替代事件；`capture:60-75` 拒绝 active lease。R9a 未改变此逻辑或 preparation 模式。既有 `tests/business_api/test_outbox_handover.py` 包含原事件状态不变、有效 receipt、active lease 拒绝、preparation 不投递原始通知和 reaper 保留状态。
5. **真实财务发布接口不重做财务。** `services/business-worker/app/main.py:41-46,266-274` 将内部 topics 绑定 `InternalPublicationTask`，财务维护仍作为每轮一次的独立 maintenance。`tasks/internal_publication.py:616-644` 验证封闭 envelope 并按同一 message.id 写 receipt；`app/modules/audit/writer.py:60-144` 使用稳定 uuid5(event_id)、已存字段一致性和冲突处理，不重复应用业务事件。既有 `tests/business_worker/test_internal_publication.py:791-840` 使用真实 LedgerService 产生事件，并断言处理后 ledger/wallet 全部表快照、余额及原审计不变。此次未改这些 handler、金额类型或账本路径。
6. **SMTP 不夸大幂等。** 真实 `tasks/wallet_alert_email.py:15-38` 仍先准备/检查 receipt，发送 SMTP，再记录回执；稳定 event_id/message-id 并不消除 SMTP 已接受而回执提交失败的重复窗口，代码已有明确说明。R9a 没有削弱现有 receipt 或宣称邮件 exactly-once。历史 DEAD/已替代 PENDING 不自动重放。

第一阶段已先向 root 报告 PASS，之后才完成以下质量/安全审查。

## 第二阶段：质量、安全与验证可信度

- **有限执行与资源归属。** 新循环无新增线程、共享 Session 或长持有 SQL 事务；实际 consumer 每次 claim/finalization 独立创建并结束事务。`messages[0]` 的单条假设由真实 SQL `.limit(1)` 保证。重试退避、最大 attempts、DEAD 和锁丢失时异常行为保持。测试 double 修改仅使成功后不再永远返回同一已终结事件，未改变 reserve monitor 产品实现。
- **证据身份匹配。** `jit-input-hashes.json` 的 8 个跟踪输入（worker、consumer、handover、模型、依赖输入与两测试）在 owner 和独立审查树逐一 SHA 匹配。历史未跟踪 `support-worker-compatibility/worker_probe.py` 只在 owner 树存在，其 SHA 也匹配 manifest；审查树没有复制或运行它，不把缺失输入误称为可在任意 checkout 直接复现全部广测。
- **RED 有行为因果。** 保存的 `jit-native-red.log` 中 PostgreSQL 双消费者确为 B→A 重复 handler、`OUTBOX_LOCK_MISMATCH`；不是连接失败。新增原生测试使用独立 consumer/session、线程 Event 和真实 PostgreSQL 提交，推进的是注入 clock；不能称墙钟执行五分钟或生产负载测试。
- **GREEN 如实复用。** 原始 `jit-green-final.log` 为 **248 passed / 1 strict xfailed / 0 skipped，17.73s**，manifest 记录 exit=0。范围是 business_worker、outbox 与 handover 相邻测试。测试数据库为本机专属 PostgreSQL **18.3**，不是生产 PostgreSQL 16 的同构压力证明；有 `postgres-stop.log` 的成功停止记录。本审查按输入不变的证据复用规则，不重启 PG、不重复跑同一广测，不把复用结果称为审查人新执行。
- **R9b 未掩盖。** `test_worker_lease_window.py:138-171` 保留 active handler 301s 的 `strict=True, raises=AssertionError` XFAIL，XPASS 或非预期异常会失败。现有 consumer 的完成检查只含 worker_id，不含 attempt fencing；同名进程与活跃操作超租约仍须单独设计。R9a 没有增加并发 owner，也没有以延长无限租约消除 crash recovery。
- **剩余成本不夸大。** claim 由每轮一次改为每条一次，并可能有一次空查询；相比批量领取增加数据库往返，已有逐条 finalization 次数不变。没有生产吞吐数据，不作性能提升承诺。需要 root 在候选/灰度边界观察有效 queue age、领取/完成速率、数据库事务/等待和 heartbeat；不为本审查追加生产压测。
- **门禁缺口明确。** `.env` 缺失导致全仓 verify 未执行，已有 preflight 明示；不得复制生产秘密完成测试。root 仍负责候选实际 import 路径、相关不变/差异输入、适用共享及 Linux/container 门禁，不能用 248 项替代全部发布检查。
- **格式检查透明。** 冻结 diff 的产品、测试、报告 `git diff --check` exit=0。包含原始 RED pytest 日志的全 diff exit=2，仅为断言打印中的尾空格；保留原日志，没有改证据来制造全 diff 通过，此项不阻断产品候选。

非阻断文案项：新增 PostgreSQL 用例后测试文件开头仍写“Only in-memory … not … a PostgreSQL lock test”。正文报告已清楚说明原生 PG 和注入时钟范围；可在后续文档清理时更新该模块说明，不能据此否定已存在的实际原生证据。

## 可部署范围与不可外推范围

允许进入后续候选准备的是精确 R9a worker 补丁及对应测试；实际发布仍取决于 root 的候选镜像 guard、当前生产基线/导入位置核验、授权范围、回退与后验。保持现有业务 API/worker 兼容 consumer、财务和 handover 配置，不为该补丁部署整个本地历史镜像，不迁移/清空数据库或重放 DEAD。

若获准发布，回退只恢复冻结兼容 worker 镜像/模块，不回滚 schema 或删除 receipt。无论是否发布，本次均不承诺 active handler 不会重复执行、不承诺 SMTP exactly-once，也不表示维护任务隔离、公平调度和任意长阻塞均已解决。R9b 需独立续租/fencing/外部副作用设计与领域复审。

下一步：root 完成候选镜像 guard；R9b 保持未完成。该审查无待 owner 修改的阻断项。
