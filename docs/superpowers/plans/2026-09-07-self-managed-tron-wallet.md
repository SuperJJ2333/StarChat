# 自建TRON钱包实施计划

> **后续用户决策：** 不再执行本计划的专属地址池和用户地址归集任务；以 [用户自有钱包方案](../specs/2026-09-07-user-owned-tron-wallet-design.md) 为下一轮实施依据。已完成只读监控不变；未完成旧任务被取消而非标记交付。

> 使用subagent-driven-development逐模块执行，先规格后质量/安全审阅。用户已授权三阶段，缺失的真实基础设施不使用占位密钥替代。

**Goal:** 先交付可持续运行的真实链只读观察，再逐步具备安全地址充值与独立出款能力。
**Architecture:** 观察服务与资金写入域分离；复用既有账本公共接口；所有真实资金开关保持失败关闭直至对应验收完成。
**Tech Stack:** Python3.12、httpx、SQLite观察存储、PostgreSQL业务存储、Docker、TRON只读HTTP。

**用户范围更新：** 用户回复“尚未准备，先完成只读监控和隔离验证”。第二/三阶段生产实现暂停在基础设施前置条件，当前执行第一阶段及现有资金边界隔离回归；不得标记后两阶段已完成。

- [x] 第一阶段adapter：`services/business-api/app/integrations/tron/reader.py`及`tests/business_api/tron/test_reader.py`。实现Base58Check、固定合约、HTTP超时/禁止重定向、分页和固化日志解析。测试错误合约、失败交易、多日志、异常数值及超时先失败再通过。
- [x] 第一阶段观察器：`services/business-api/app/integrations/tron/observer.py`及`tests/business_api/tron/test_observer.py`。持久水位/事件唯一性/中断不推进/重启重放/异常转出及余额截点不确定状态；不写金融表。合成地址测试，不提交真实地址。
- [x] Root接线与部署：独立CLI、只读HTTP真实联通、服务器受保护地址配置、进程健康与脱敏状态；不替换主业务服务或开放充值。先审阅再运行持续监控。
- [ ] 第二阶段：安全地址池设计与数据库事务实现；先验证并发分配、不可重分配、幂等、审计Outbox及无控制权证据拒绝启用。两个独立最终性来源到位前不自动入账。具体文件及迁移号在核对当前head后锁定，避免覆盖并行工作。
- [ ] 第三阶段：签名协议、审批摘要、限额与熔断验收；真实设备和人员依用户回复配置，缺失时完成隔离合同测试并明确剩余事项，不称为已签名或已开放。
- [x] 当前只读范围：领域审阅、随后安全审阅、专项与全仓库验证、各阶段证据入`docs/verification/artifacts/2026-09-07/tron-wallet/`。

本轮不提交其他任务已有修改、不打印敏感环境、不把真实地址写入Git文件。shell使用pwsh7和UTF8；测试`py -3.12 -m pytest`，PYTHONPATH包含services/business-api。
