# 窗口外充值人工补录执行计划

用户已授权功能；架构见[ADR0069](../../adr/0069-manual-deposit-cases.md)。当前工作区保留所有既有修改，最多两个显式gpt-5.6-terra执行者，共享文件串行。Astra先领域/规格审查，再质量安全审查，最后亲跑门禁，不以代理总结代替diff。

- [x] M1 领域与安全设计复核。Astra拥有ADR/计划/任务记录；Terra只读复核绑定、收据、账本、审批与跨类型幂等。late_deposit_backend领域、late_deposit_ui独立安全评审通过，Astra确认实现方案；不以设计评审替代最终代码审查。
- [x] M2 后端（按任务记录串行移交Terra）：新增wallet/manual_deposit_cases.py；repair_models.py、receipt_models.py、repairs.py、repair_payouts.py、finance_queries.py；admin_wallet_repairs.py；0066迁移、wallet_release_preflight相关head断言、相关tests/business_api/wallet及迁移测试。先red再实现。未改账本公式/金额精度/旧订单时间/旧权限。独立case→决定→预检→执行、回放/并发唯一、拒绝/回滚、普通路径兼容经主线程专项通过；API/OpenAPI同步。真实PG0065→0066、原生约束及HTTP流程已验证。
- [x] M3 前端（契约冻结后接入）：frontend/src/admin-manual-deposit-case.js新增，admin-wallet-repair-dialog.js接入入口，admin-api.js追加API方法；frontend/tests新增独立case交互测试。保留前轮客服/钱包修复。系统归属展示、审批、预检不入账、二次执行、原key恢复、刷新失败提示已完成；主线程最终node199通过，浏览器合成流程已走通。UI契约随综合门禁验收。
- [x] M4 Astra最终验收：亲读实际diff和完整资金调用链；定向后端、真实隔离PG并发/迁移、前端全量、OpenAPI/唯一head/离线迁移/verify环境预检及适用全量，Flutter存在外部6文件变化，前轮2508只作历史证据，本轮移动边界70通过。保留日志/hash和外部环境缺口。更新runbook/current-state与交付报告。无生产部署/实际补款。

审计关联：延续ADR0066的TEMPORAL_EVIDENCE_REQUIRED限制，本次验收编号M1–M4；用户两txid只作只读诊断背景，自动化仅用synthetic链证据。
