# R9b：活跃 handler 超租约的有界分析

2026-10-11；`backend_review`；基于批准的 R9/A7-4 与冻结源码 `9e036261be1e3ba87d106c38737675c7f46b35fb`。本次仅阅读源码与既有证据、写本文件；没有修改产品、执行新产品测试、访问服务器或部署。R9a 的现场部署及后验由 root 负责，不在此处推断结果。

## 结论与最小范围

**可以不新增 schema、不改金融 handler，降低健康运行期间 active handler 超过 300 秒被重复领取的概率；但必须把续租与领取代次校验一起设计。** 只在后台不断更新 locked_at 不足以安全交付：当前完成检查只有固定 worker_id，没有区分同名进程或下一次 claim。

推荐首先领取一个独立小步骤 **R9b-1：有代次约束的 consumer 原语及并发测试**，只新增 `renew_claim` 和同事务的 `complete_claim` 公共接口，不连接续租线程、不改变现有 worker 运行行为。它可单独 RED→GREEN 和双审；现有 active strict XFAIL 暂保留。随后 R9b-2 才接入单 active handler 的有限续租生命周期。不要把这一步称为已修复 active 重复执行。

不推荐把租约简单加长：只是延后故障出现并拉长 crash recovery。不推荐首批引入新队列、跨 topic 并发或修改钱包任务：均不属于这个已确认根因。

## 已确认的调用与归属事实

- `services/business-api/app/core/outbox.py:28,37-46,132-137`：attempt_count 是已有整数字段，每次实际领取递增，消息对象携带该值。当前仓库内 Outbox 的生产赋值只有创建为 0、领取时递增，未发现生产代码重置它的路径。
- 同文件 `95-137`：claim 是独立短事务，按可用时间/主题/有效 handover 排除条件选择，领取后释放 DB 锁再执行 handler；租约默认 300 秒。`208-224` 的完成锁只检查 id、PROCESSING、worker_id，未检查 attempt_count。
- `services/business-worker/app/main.py:270` 默认 WORKER_ID=`business-worker-1`；仅 worker_id 不能识别同名进程 A 的旧 attempt=1 与 B 的新 attempt=2。
- `worker.py:149-192` 在 R9a 后一次只执行一个 active handler；重试/DEAD/finalization 在同一线程，heartbeat 在整轮结束时更新。`docker-compose.yml:352` 的本地健康检查要求 heartbeat 小于 30 秒。不能让续租线程顺手更新它，把 handler 挂住伪装为任务有进展；实际部署健康/重启策略须在激活续租前核对，本次没有新现场查询。
- 既有 strict XFAIL `tests/business_worker/test_worker_lease_window.py:138-171` 用真实 consumer + 注入时钟，得到 A-enter→B-enter→A-exit 及旧归属确认失败。它是确定的调用重复证明，不是生产已重复记账证据。
- 真实 SMTP 路径 `tasks/wallet_alert_email.py:15-38` 在发送后才落 receipt；`integrations/email_sender.py:297-315` 的 10 秒默认 socket timeout 不是整个 handler 的可强制取消总期限。已有 stable message-id/receipt 仍不保证 SMTP exactly-once。内部财务事件则由 `tasks/internal_publication.py:616-644` 写稳定 event_id 对应的不可变 receipt，不重新执行资金业务。

## R9b-1 可实施的小步骤

**产品文件仅** `services/business-api/app/core/outbox.py`；测试可新增 `tests/business_api/test_outbox_claim_ownership.py`，并复用现有 lease/Outbox/handover/receipt 测试。本步骤不改 `worker.py`、`main.py`、财务 handler、handover、schema、租约长度或生产配置。

1. 用已有字段定义不可变 claim token：`(event_id, worker_id, attempt_count)`。attempt_count 必须来自本次 `OutboxMessage`，不能从 DB 读“最新值”后冒充旧请求的身份；它是内部领取代次，不是对外授权凭证。禁止通过重置历史 attempts 绕过代次。
2. 新增 `renew_claim(token)`：只在独立短事务中，对 id/status=PROCESSING/worker_id/attempt_count 全匹配、且**尚未过期**的 claim 更新 locked_at。不得修改 payload、attempt_count、available_at、receipt 或任何金融表；过期不能续活，被接管不能续活，DEAD/PUBLISHED 不能续活。
3. 续租必须在取得该行锁后用新鲜时间判断是否过期，避免锁等待期间已过期却用进入函数前的旧 now 续活。建议续租用 NOWAIT 行锁，拿不到锁归为有限的 UNKNOWN/争用，不把慢行锁变成后台无限等待。R9b-1 先冻结可注入的 lease-clock 接口，测试 claim/renew 使用同一时钟，不切换现有 claim 的默认行为；R9b-2 生产激活时，所有租约判断统一采用 DB 时基。不能仅让 renew 改用 DB 时间而让并行 claim 仍依赖不同机器墙钟。
4. 新增 `complete_claim(token, outcome, ...)`：在同一个锁定事务里验证代次并做 SUCCEEDED/FAILED/DEAD 的既有状态变换；不能先检查 token、释放事务，再调用旧弱校验方法。FAILED 保留既有 retry_at、DEAD 保留原错误与审计边界，稳定 message.id 不变。可复用内部 helper，现有公共方法保持兼容；R9b-2 的新 Worker 必须全路径调用有代次约束的新接口，不能隐式退回旧接口。
5. 完成与续租分开：续租不允许复活过期 claim；**handler 已完成且该 attempt 尚未被接管时**，可保留现有完成语义，原子落最终状态以避免已经成功的副作用被无谓再投递。若竞争者先领取，新 attempt 必须使旧 success/fail/dead 全部拒绝。过期未接管允许最终确认不等于延长租约；该明确语义须纳入领域审查与竞争测试。
6. 把结果分为 SUCCESS、LOST（条件不匹配）、UNKNOWN（连接/锁/提交结果不确定），只输出固定原因码。不能把 UNKNOWN 当成功；也不能在提交响应丢失时直接清空锁或标失败。原语不碰当前事件以外的行，不读取或记录 payload/地址/密钥。

**完成边界：** 原语测试、真实隔离 PostgreSQL 竞争、既有 Outbox/receipt/handover 相邻回归通过，规格/领域先于质量安全审查；active XFAIL 仍保留。旧 Worker 未接入前运行行为不变，因此此步骤本身不需要生产部署。新原语与运行 worker 的实际 import 位置必须绑定，不能只覆盖不执行的 `/opt/business-api/app` 副本。

## 后续 R9b-2 激活续租的必要边界（本轮不实现）

- 每进程仍最多一个 active claim；每个 active claim 最多一个 renewer。独立 Session/短事务，不共享 handler Session。先确认 claim 所属代次，再开始 handler；结束时停止/收敛该 renewer，杜绝旧任务的续租线程污染下一任务。
- 保留 300 秒租约，候选续租周期可从 60 秒开始；DB connect≤3s、lock≤1s、statement≤5s，池等待也必须有界。若共用池无法保证这一预算，在 worker 本地给 renewer 最多一个独立连接，随进程生命周期释放，不改变整个 API 的池配置。
- scheduler 用单调时间安排周期，租约裁决用统一 DB 时间。续租/查询结果未知时只允许在最后确认租约仍有效的窗口内做有限重试；没有新的确认不得假定租约继续有效。代次丢失后停止领取新事件、不把当前任务改成 DEAD、不“释放”别人的锁。
- 同步 handler/外部请求无法被线程 observer 安全强制终止。lease LOST 后可能继续发生迟到副作用；只能拒绝旧代次的队列状态覆盖，并等当前 handler 收敛后停止该执行轮次。不能以超时显示失败后立即在同一进程启动第二个真实调用。
- 不能无限自动续租掩盖死锁。激活前须按实际 handler 操作总期限冻结最长自动续租预算和超预算处置；当前仅有局部 socket timeout，不能据其推算一个真实总期限。若希望超预算后仍严格禁止迟到副作用，需要 provider 幂等/fencing 或可隔离执行与明确恢复协议，不能靠纯 lease 完成。
- 分开观测 worker 进程存活、claim 归属、handler 运行年龄和最后任务完成时间。lease 续期不是工作进展；30 秒 heartbeat 的健康语义不能在此步骤偷偷放宽。激活前验证部署编排不会因长任务的健康状态制造意外重启循环。

## 失效与可保证范围

| 场景 | 应有行为 | 不能保证的部分 |
| --- | --- | --- |
| 正常活跃 301s，续租健康 | 同一 attempt 延续，其他 consumer 不能领取，完成一次 | 不代表任意时长任务都健康 |
| 两 renewer / same WORKER_ID 不同 attempt | 只接受当前 attempt；旧 renew/finalization 不改行 | 不能撤销旧 handler 已发出的请求 |
| DB 锁等待/连接卡住/提交回执丢失 | 有限超时、UNKNOWN；不得复活过期 claim 或凭空 ACK | 暂时不能确认租约，外部调用可能仍在执行 |
| DB 分区或整个进程暂停超过租约 | 竞争者可恢复；旧进程恢复后 token 失效 | 外部系统若不识别 token，可能已经产生两次效果 |
| 进程真正死亡 | renewer 同时消失，最后一次确认租约期满后可重领 | SMTP 已接受而 receipt 未落库仍可能重发 |
| handler 返回与竞争 claim 同时发生 | 行锁 + attempt fence 决定唯一状态胜者；旧代次不能覆盖新代次 | 这是队列状态原子性，不是跨外部服务的 exactly-once |
| handler 永远阻塞而 renewer活着 | 运行年龄告警，有限自动续租预算；按已冻结恢复方案处理 | 不能同时凭空保证无限 crash recovery 与零重复副作用 |

## 精确 RED 测试清单（尚未执行）

**R9b-1 先实现的测试：**

1. `renew_preserves_payload_attempt_and_business_tables`：A attempt=1 在 t=60 续租，仅 locked_at 改变；t=301 B 不能领，t=360 才可恢复；payload/headers/receipt/attempt/金融快照不变。
2. `expired_claim_cannot_be_renewed`：t=300 的到期边界拒绝 A 续租，即使尚无 B；299 秒允许。状态不能从 DEAD/PUBLISHED 被续活。
3. `same_worker_id_old_attempt_cannot_renew_or_finalize`：A 与 B 均叫 business-worker-1；B 在过期后取得 attempt=2。分别调用 A 的 renew/success/fail/dead，全部拒绝且 B 行逐字段不变。
4. `renew_lock_wait_does_not_revive_expired_claim`：真实 PG 独立连接持行锁，A 续租遇 NOWAIT/受限锁等待返回 UNKNOWN；释放时已到期，后续重试仍拒绝。不能把函数入口的早期 now 当成完成时 now。
5. `finalize_races_reclaim_without_state_regression`：真实 PG 两连接屏障控制两种先后；A 完成先取得锁则终态阻止 B 领取；B 领取先取得锁则 A 的 attempt=1 确认拒绝；固定 worker_id 也成立。
6. `renew_commit_response_lost_is_unknown_not_success`：注入“DB已提交但客户端响应丢失”与“未提交”两分支；caller均不得盲认成功、清锁或 ACK，后续精确 token 查询区分。
7. 原 crashed-owner 299/300 秒控制、handover preparation/not_superseded、退避/DEAD、lost ACK 单 receipt、真实 ledger snapshot 不变回归继续通过。不得以新原语绕过旧数据保护。

**R9b-2 才转绿的测试：** active 301 秒加周期续租不出现 B-enter；暂停 renewer 超过租约时 B 可恢复且旧代次最终确认失败；handler Session 与 renewer Session 不同、并发连接有上限；结束/异常/SIGTERM 无遗留 renewer；renewal 不刷新工作进展 heartbeat；SMTP 成功但 receipt 丢失仍明确标 at-least-once。测试必须有独立 PostgreSQL 两连接/两个执行上下文，不能只用 SQLite 或 mock claim 宣称竞争已验收。

## 审查与 ADR 边界

最小 R9b-1 只增加内部队列原语，不改变金融状态、schema、E2EE、OpenAPI 或托管策略，根 AGENTS 没有因此自动要求一份新金融 ADR；仍须规格/领域→质量安全审查，特别审查同名代次、有效 handover、receipt 与发布兼容性。若实施范围转为改钱包状态/财务 handler、provider/custody 协议、自动隔离/重放财务事件或跨域保证，则进入受保护变更：先 ADR 与领域审查，不沿用 R9 授权扩大范围。

本轮交付是可实施的小步骤和明确的后续激活门槛；没有宣称 R9b 已修复。下一条可执行工作是为 R9b-1 新增上述 consumer 原语失败用例，并保持生产与现有 active XFAIL 不变。
