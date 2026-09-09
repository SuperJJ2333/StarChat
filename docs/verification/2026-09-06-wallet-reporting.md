# 钱包日流水预览验证

2026-09-06。承接用户“继续”执行要求，本轮交付已批准安全补充设计 §7 中可独立验收的内部账本报表预览。没有部署生产或启用真实资金，没有改动已验证 Android APK。

## 实现与边界

- GET `/api/v1/admin/wallet/reports/daily?day=YYYY-MM-DD&format=json|csv`，财务权限或系统管理员可用。
- 同一 UNION 查询快照读取点钻/USDT 两个账本，通过点钻账本公共只读接口组合；香港日界线映射 UTC 左闭右开。
- 全账户期初、增加、减少、期末和分录证据；含平台、冻结、托管账户。逐笔交易按来源与资产检查平衡，不能用两笔相反错误抵消。
- 金额字符串；Decimal 精度 60；拒绝无效资产、非有限值及异常精度。10 万条完整证据上限，超过明确拒绝，不输出部分报表。
- 捕获内容摘要、CSV 公式防护、成功查看/导出审计、成功及错误 no-store。审计成功提交后才返回报表。
- `finalized=false`：当前事务快照预览。不是锁定持久截止序号的最终日结，不是外部审计签名，不包含尚未过账的待处理状态或托管余额证据。后补提交可能改变下一次预览摘要。

## 测试与审阅

API 缺少端点先红 6 项；实现后通过。新增坏资产分类及错误缓存断言分别观察到预期失败，再修复。API 8 项加服务 SQLite 18 项，共 26 项通过；另对 SQLite 与随机隔离 PostgreSQL schema 执行服务测试，30 项通过。覆盖午夜边界、尾数、大数精度、冻结/平台账户、单笔失衡、限额拒绝、公式/控制字符、未来日期、权限与审计。

领域审阅发现错误响应缺少禁止缓存头，已补齐四个统一错误处理器并复核通过。随后 Quality/Security 审阅通过；两项审阅均仅批准本轮预览范围。

最终 scripts/verify.ps1 PASS：524 项通过、21 项跳过；OpenAPI、UI 契约、AST、迁移离线生成及 Compose 检查通过。详见 [repository-verify.txt](artifacts/2026-09-06/wallet-reporting/repository-verify.txt)。既有 Starlette/httpx 与 Pydantic 依赖弃用警告保留；本轮没有宣称完整历史 PostgreSQL 迁移升级通过。样例已独立重算摘要并通过公开响应模型校验，git diff --check 通过。

## 可查看样例

由真实应用服务在隔离 SQLite 中生成合成充值 100.123456 USDT、兑换 10.123456 USDT、提现冻结 10 USDT。样例期末为可用 80.003456 USDT、冻结 10.000000 USDT、10.12 点钻；每笔交易平衡。

- [JSON 样例](artifacts/2026-09-06/wallet-reporting/sample-daily.json)
- [CSV 样例](artifacts/2026-09-06/wallet-reporting/sample-daily.csv)
- [生成及断言脚本](artifacts/2026-09-06/wallet-reporting/sample_report.py)

测试和样例不使用真实账户、地址或资金。没有更改资金过账、审批、风险冻结或生产工厂规则；全局错误响应仅增加禁止缓存头。

后续仍需持久化日终封账/独立归档、待处理账龄和运营分类视图、异常事件 ACK/升级/通知及处置闭环。原先的真实托管、灾备、完整历史迁移及 iOS 验收限制继续有效。用法见 [运行手册](../runbooks/wallet-daily-ledger-preview.md)。
