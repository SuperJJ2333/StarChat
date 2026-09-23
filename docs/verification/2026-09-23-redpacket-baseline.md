# 红包第一批基线与优化决策（2026-09-23）

## 结论

现有 PostgreSQL 事务模式通过本轮隔离竞争验证。热点红包锁持有期间执行成员校验，是下一批优先研究的路径；尚无 Redis 对照测量，不报告 Redis 提升倍数。现有代码已经预拆份额，重复实现预拆分不会产生该项额外收益。

## 证据与范围

- 源码 commit：`398ffbd55f8f3ea6f4d1ac7f95444751561a4713`；关键文件、锁文件、探针 SHA 与环境见 [environment.json](artifacts/2026-09-23/redpacket-baseline/environment.json)。工作区存在其他任务的 pubspec 与交付文档变化，未修改这些文件。
- Windows / Python 3.12.10 / SQLAlchemy 2.0.52，Docker PostgreSQL `16.9-alpine`（image ID 记录在环境文件）。连接池固定 25，零 overflow。直接调用当前 RedPacketService，无 HTTP 层。
- 新建容器 `starchat-rp-baseline-20260923-1445`，随机 localhost 端口，独立 `redpacket_baseline` 数据库；仅合成账号和测试记账，不接触生产。
- 真实 Alembic `upgrade head` exit 0，迁移到 `0087_support_payout_workflow`。原计划假定 0084 可用已过期。
- `PYTHONPATH=services/business-api; py -3.12 -m pytest tests/business_api/redpacket -q --durations=5`：46 passed / 8.62s，exit 0；[日志](artifacts/2026-09-23/redpacket-baseline/regression-py312.log)。这是正确性回归时间，不是性能结果。
- 探针：`PYTHONPATH=services/business-api; py -3.12 docs/verification/artifacts/2026-09-23/redpacket-baseline/probe.py <本次随机端口>`，exit 0；[结果](artifacts/2026-09-23/redpacket-baseline/results.json)、[日志](artifacts/2026-09-23/redpacket-baseline/probe-migrated.log)。重跑应使用新的隔离容器及空数据库，先跑真实迁移。

## 实测（三轮范围，不合并百分位）

| 场景 | 全部响应 P95 | 成功领取 P95 | 全部响应结束时间 |
| --- | --- | --- | --- |
| 25 请求抢 10 份，无外部校验延迟 | 209–254 ms | 181–230 ms | 0.214–0.273 s |
| 100 请求抢 10 份，无外部校验延迟 | 327–337 ms | 169–202 ms | 0.349–0.379 s |
| 500 请求抢 10 份，无外部校验延迟 | 1059–1065 ms | 200–223 ms | 1.151–1.174 s |
| 100 请求抢 100 份，无外部校验延迟 | 1459–1643 ms | 相同 | 1.545–1.754 s |
| 100 请求抢 100 份，校验模拟增加 20 ms | 3537–3599 ms | 相同 | 3.730–3.794 s |

18 轮、2478 次请求、693 次成功；每轮成功数与份额数相符，领取记录数一致、红包托管清空、每笔每资产分录平衡。100 份全成功场景本地提交吞吐由约 57–65/s 降至 26–27/s，说明锁内外部等待对该场景敏感；20ms 是注入的假设，不是真实 Synapse 测量，也不是优化前后对比。失败请求快速返回的吞吐不能当作记账 TPS。

## 发现与下一步

1. `RedPacketService.claim` 先获取红包主记录 FOR UPDATE，再进行 `_authorize_room_access`；真实成员实现通过独立 session 解析 Matrix ID，再调用网关读取成员。同一红包的事务串行，份额层 skip_locked 不能绕开已持有的主记录锁。
2. 下一批先增加 HTTP/真实成员网关分阶段测量，区分连接池等待、红包行锁、成员网关、ledger 和提交。不能仅将鉴权移出锁或缓存成员就宣称安全；退群/踢人/不可达必须继续拒绝未授权领取。
3. 可评估已经终结的红包快速失败、合规限流、缩短持锁时间。每项先补行为回归、故障/竞态用例，保持数据库内最终校验和原子记账。没有获得证据前不删除锁。
4. Redis 异步模式潜在收益是入口削峰、减少无效 DB 请求、缩短抢领受理耗时；账本、审计、Outbox 总工作不会消失，余额到账仍受数据库吞吐约束。新增排队状态、持久性、退款栅栏、去重、回切成本必须单独 ADR。

## 失败与限制

- 首次系统 Python 3.11 收集失败：缺 argon2，exit 2，日志保留。改用仓库门禁要求的 Python 3.12，未安装或更改依赖。
- 探针首次 ORM create_all 失败：Boolean `fee_exempt` 的 ORM default 为整数，PostgreSQL 拒绝，exit 1。真实 0074 迁移使用 sa.false()；改为跑真实迁移链，未修改产品模型、未将该差异误报为生产迁移失败。初次失败日志保留为 probe.log。
- 这是当前单机、线程客户端、合成数据、静态成员替身的服务层基线；不含真实 HTTP、用户鉴权、Synapse、群主注册表/抽成负载、worker、跨实例、退款竞态和生产数据规模。46 项回归包含现有抽成场景，但不等于 PostgreSQL 抽成并发验收。
- 没有产品可执行代码变更，未运行全仓 verify/移动构建，未部署。未声称消息千人群容量已测。
- 自审顺序：先核对财务权威、事务、成员权限边界未变；再核对隔离、退出码、百分位与吞吐口径、样本局限和源码身份。
