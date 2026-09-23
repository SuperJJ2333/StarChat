# 红包终态查询优化：实现与前后对比

日期：2026-09-23，时区 +08:00。用户授权：执行上一轮优化方案。无生产发布。

## 结果与实现

`RedPacketService.claim` 的同一条 SELECT FOR UPDATE 增加 `status='OPEN'` 和 `expires_at > now`。已经不可领取的红包无需获取行锁；活动红包仍按原顺序锁记录、检查状态、检查成员权限、写领取、记账、结算抽成及提交。没有增加查询、缓存、Redis、异步资金流程或迁移。

不改变分配算法、金额、状态机、授权顺序、幂等契约、审计及 Outbox；这不是受保护的红包算法重构。原有 now 在等待前获取的语义保持不变，未顺带改变过期边界。查询开始时仍开放的红包，可能仍须等待竞争事务提交。

## 测试先行证据

- 旧实现：新增 PG 用例 4 failed、2 passed，exit 1。4 个失败均为已完成/已取消/已退款过期/时间过期的记录被其他事务持锁，领取触发 PostgreSQL lock_timeout，而不是预期 unavailable。
- 新实现：全部红包用例 52 passed，exit 0，18.22s。包括上述 4 场景、20 请求争抢 3 份并验证用户余额/托管/领取数/分录平衡、竞争最后一份后失败请求不重复入账。
- 测试最后一份场景只证明等待后业务正确性，不将其单独表述为证明 SQL WHERE 重检。
- 审查后为每个 PG fixture 增加唯一 application_name，避免并行测试误认其他连接的锁等待；最终版本又单独执行真实 PG 6 项，6 passed / 1.26s / exit 0（final-postgres.log），明确证明没有因可选环境缺失而跳过。

## 同环境前后对比

同一台机器、同一 PostgreSQL 16.9-alpine 容器，分别新建 before/after 数据库并运行实际迁移链到 0087。相同 Python 3.12、探针、25 连接池、合成数据、6 场景各 3 轮；先旧代码后新代码，各 18 轮，均 exit 0。运行时未同时执行完整门禁。

下面是三轮各自 P95 的中位数，不是合并样本百分位。

| 场景 | 旧全部响应 P95 | 新全部响应 P95 | 变化 |
| --- | --- | --- | --- |
| 25 请求抢 10 份 | 213.37 ms | 200.93 ms | -5.8% |
| 100 请求抢 10 份 | 333.00 ms | 210.40 ms | -36.8% |
| 500 请求抢 10 份 | 1092.87 ms | 401.37 ms | -63.3% |
| 100 请求抢 100 份 | 1513.62 ms | 1541.02 ms | +1.8% |
| 100 请求抢 100 份，模拟成员查询 20ms | 3448.63 ms | 3416.19 ms | -0.9% |

500/10 场景全部请求结束时间中位数 1.178s→0.480s。成功领取 P95 中位数 217.18ms→225.94ms（+4.0%），没有到账提速证据。100/100 完整入账场景近似持平，不能宣传普遍吞吐倍增。样本仅三轮、非 ABBA 随机交错，可能受环境与顺序影响；百分比只描述本轮结果，不是生产 SLA。

前后各 2478 请求、693 次成功；每轮成功数/领取数等于份额数，托管清空、各笔各资产分录平衡。拒绝吞吐与成功提交吞吐分别记录。静态成员替身、直接 service 调用、不含真实 HTTP/Synapse、多实例、生产数据量或群主抽成压测；抽成既有回归保留。

## 审查

按 requesting-code-review 技能安排独立只读审查：先规格符合性通过，再质量/安全通过，无必须修复项。采纳唯一 application_name 建议；报告明确等待测试与时间快照的边界。查询过滤不替代权限与资金锁，未触及保护规则。

## 验证与证据位置

原始证据在 [本任务产物目录](artifacts/2026-09-23/redpacket-claim-filter/)。包含 red.log、green.log、before.log、after.log、comparison.json、两份原始结果、迁移日志、探针、verify.log 和环境/输入 SHA。

完整 `pwsh -NoProfile -File scripts/verify.ps1` exit 0 / Verification PASS。业务 API/worker 2622 passed、65 skipped、1 warning（1553.39s）；infra 144 passed，getui 28 passed/2 warnings，bot 9 passed，mobile boundary 108 passed/1 skipped。UI drift、AST 266 文件、Alembic、OpenAPI、Compose 全部通过。跳过项不算通过；独立真实 PG 6 项的执行证据另外保留。

测试环境只复制仓库 `.env.example`，没有导入生产秘密。既有 getui-bridge 警告来自 Pydantic class Config 弃用及 Starlette/httpx TestClient 弃用，业务警告也是 TestClient 弃用，属于未改动模块/运行时依赖；不压制警告，也不借本次查询优化扩大依赖升级范围。

## 交付与后续

源码候选位于 `codex/redpacket-claim-filter` 工作树，通过验证后仅回填本任务文件，逐文件 SHA 核对见 integration.json。无需 schema 回退；回退只还原 claim 查询过滤条件。不发布、不开新资金开关。下一项如处理锁内真实成员网关延迟，应先单独设计退群/踢人权限竞态，不直接挪动鉴权或引入过期成员缓存。

回填到主目录 HEAD `7140ace247d1874fea0285914c5696e3c0212370`；与测试基线相比仅另一任务的 AppConfig/pubspec 版本号及其交付文档改变，services/tests/scripts 无差异。保留版本 0.4.2+2161。补跑 `tests/mobile/test_app_build_contract.py` 2 passed / exit 0，UI contract 32 components / 398 screens PASS / exit 0。最初重复启动的整个主目录 mobile 扫描在历史产物秘密字面量扫描中主动取消，外层脚本 exit 1（取消，不是业务断言失败）；日志保留，不算通过。复用干净工作树 mobile 108/1 与本次候选安全检查，并参考另一任务的版本门禁16项/Flutter专项31项证据，仅复核变化输入，未重跑等价后端门禁。
