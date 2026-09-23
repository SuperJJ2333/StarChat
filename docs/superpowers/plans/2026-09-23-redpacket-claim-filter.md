# 红包终态领取查询优化执行计划

**授权：** 用户 2026-09-23 明确要求执行上一轮基线报告中的优化方案。
**目标：** 已终结、已过期红包的领取不等待该红包行锁；仍可领取的红包继续使用原有原子事务。
**设计：** 在现有 SELECT FOR UPDATE 添加 `status == OPEN` 与 `expires_at > now`，保留事务内最终判断。只有不可领取请求提前拒绝，不改变金额、分配、权限、幂等响应、抽成、退款和 Outbox，无 schema 或 OpenAPI 修改。此批不是红包算法或状态机改造，不新建资金 ADR。
**技术：** SQLAlchemy / PostgreSQL READ COMMITTED / pytest。无 Redis、新缓存或跨事务预占。

## 所有权

- `services/business-api/app/modules/redpacket/service.py`：仅领取加锁查询。
- `tests/business_api/redpacket/test_claim_filter_postgres.py`：真实 PostgreSQL 锁竞争回归。
- 本计划、`docs/workflow/tasks/2026-09-23-redpacket-claim-filter.md`、`docs/verification/2026-09-23-redpacket-claim-filter.md`。
- `docs/verification/artifacts/2026-09-23/redpacket-claim-filter/`：本任务验证产物。

## 步骤

- [x] 先写真实 PostgreSQL 回归：完成/取消/过期/时间过期四种记录由其他事务持锁时，claim 返回原有 unavailable 而不是 lock_timeout；检查无额外资金变化。
- [x] 旧实现跑出 lock_timeout 失败，保存日志。
- [x] 最小修改：`select(RedPacket).where(RedPacket.id == packet_id, RedPacket.status == "OPEN", RedPacket.expires_at > now).with_for_update()`。
- [x] 新实现通过；增加并发争抢与等待期间最后一份被领取的回归，证明数据库重检生效，不删除终态检查。
- [x] 对同样的隔离 PG、相同探针分别跑旧/新代码各 18 轮，分开记录已抢完响应和成功记账。
- [x] 预检完整 verify 所需环境后运行 `pwsh -NoProfile -File scripts/verify.ps1`，记录真实退出码；原有无关失败按基线复现，不隐瞒。
- [x] 先规格符合性，再质量/安全审查；记录性能收益、活跃红包成本及局限。

## 风险与回退

过滤条件只减少不合格记录的加锁；不能用它替代事务内权限与资金验证。终态不恢复 OPEN 是现有状态机前提。若实测无收益或活跃场景明显退化，保留测试/报告而撤回代码。回退仅还原此查询，无迁移，无生产操作。独立工作树验证完成后仅回填本任务文件，不覆盖其他任务。

