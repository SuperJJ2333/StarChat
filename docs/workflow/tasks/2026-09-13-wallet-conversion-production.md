# USDT/点钻线上兑换与两笔历史补兑换

- 状态：领域核对与实现准备；用户已明确批准自动充值兑换与两笔历史实际兑换，不需重复询问是否继续。
- 负责人：Astra；执行模型由 spawn_agent 显式 gpt-5.6-terra，初始只读测试 conversion_audit 已创建。
- 计划：[执行计划](../../superpowers/plans/2026-09-13-wallet-conversion-production.md)，[ADR0070](../../adr/0070-deposit-auto-conversion.md)。
- C1发现：生产 conversions_enabled=true、manual_liquidity；已有双向API和APP UI。真正缺口为收据入账后自动兑换。此前“兑换未实现”判断已向用户更正。
- 14:13 +08只读：ab0ddd6a…74c09/0 与16f1f166…acbe3/0 均CREDITED各10.000000 USDT，归属同一用户，当前USDT20.000000、点钻11.97，无本次收据关联兑换；真实执行前必须重读。未在本任务执行资金写。
- 当前 API dc41eb54，Compose finance-six-20260913-r2；worker7e0e9ffc。其他任务已更新生产，必须保留。
- 证据目录：docs/verification/artifacts/2026-09-13/wallet-conversion-production/；准确起点未记录，14:11:51起有工具时间。下一步领域审阅后实施C2，文件独占不交叉。

## 本轮历史执行范围（来自用户明确指定）

| txid / log_index | 已核对收据 | 金额 |
| --- | --- | --- |
| ab0ddd6a2723884b6ffe323ad4260aa1e25d61ecd398d5b20d35aee225a74c09 / 0 | 5bcd3d76-cfc4-4dd8-b3c1-d800f16b800a | 10.000000 USDT → 10.00 CAIBI |
| 16f1f166b7b0e776f6c5529777e2eff11c9b9223b0b4ae906758f578118acbe3 / 0 | eaffca1b-d9a0-43db-b5a0-e81af3354fa5 | 10.000000 USDT → 10.00 CAIBI |

两笔均归用户 484ce553-6452-4a1b-9d14-2f0fe30988cb；执行清单需重新查询并核对，不能凭此历史快照跳过服务检查。此处只记录用户本次授权的两笔，不包含其他充值。

14:29 +08：C2a/b helper审查返工已完成，57项专项通过；C2c三路径/故障回滚/PG并发执行中。发布工具R2按实际compose/inspect防漂移返工中。两Terra继续文件独占，未生产资金写。

2026-09-13 Astra 实现领域/安全复核：已亲读 8 个 API 文件 diff、新应用方法和 worker retry 调用链。收据原信用证据、两资产平衡、实际 actor、内部键拒占、金额截断尾数、身份/暂停/储备、嵌套 savepoint 及三个入账入口均已检查。77 项针对测试亲跑通过（包括 PostgreSQL 并发、历史两笔原子失败恢复及重放）。全量后端1907通过/57跳过，唯一新增PG环境KeyError已修复并真实PG复跑通过；未因环境skip声称通过。verify后续门禁单独续跑通过。准许构建和隔离验证候选；生产切换仍须候选镜像验证通过。无schema变化，保留0066现有head。

## 生产与历史执行完成
2026-09-13 15:07 +08切换API/worker候选，隔离恢复API101/worker2通过；随后精确两收据原子兑换成功，CAIBI11.97→31.97，USDT20→0；实际重放证据未变。详见[生产验收](../../verification/2026-09-13-wallet-conversion-production.md)。保留worker既有Outbox无消费者告警，不声称事件已投递。下一步用户真机刷新两条+10充值账单；本地PG及SOCKS已关闭。
