# USDT—点钻设计补强与离线 Sandbox 验证

日期：2026-09-06。授权：用户要求继续设计及 Sandbox 验证，无需托管商参与。运行位置：本地 Windows / PowerShell 7。未连接托管商、未生成签名或链上交易、未修改生产应用代码和数据库。

## 交付与可复现性

- 规范：[安全补充设计](../superpowers/specs/2026-09-06-wallet-safety-supplement.md)，原技术设计与 ADR-0010 同步修订。
- 计划：[本轮实施计划](../superpowers/plans/2026-09-06-wallet-sandbox-hardening.md)。生产双重批准仍未授予。
- 可执行模型：[wallet_model.py](artifacts/2026-09-06/wallet-sandbox/wallet_model.py)。标准库 SQLite 内存事务，独立的内存外部订单模拟，不是现有业务 WalletService。
- 测试：[test_wallet_model.py](artifacts/2026-09-06/wallet-sandbox/test_wallet_model.py)。正常运行 23 个测试，其中一个测试包含固定种子的 100 组金额往返。
- 反例：[mutation_check.py](artifacts/2026-09-06/wallet-sandbox/mutation_check.py)。只在内存中关闭 7 个控制，原模型文件不变。

命令从仓库根目录执行，首先配置 UTF-8 与 `PYTHONUTF8=1`、`PYTHONIOENCODING=utf-8`：

```powershell
python -B -m unittest discover -s docs/verification/artifacts/2026-09-06/wallet-sandbox -p test_wallet_model.py -v
python -B docs/verification/artifacts/2026-09-06/wallet-sandbox/mutation_check.py
$env:PYTHONPATH='services/business-api;services/business-worker/app;.'
py -3.12 -m pytest tests/business_api/wallet tests/business_worker/test_wallet_task.py -q -p no:cacheprovider
pwsh -NoProfile -File scripts/verify.ps1
```

## 模型证据

| 项目 | 证据 | 结论 |
|---|---|---|
| 初次红灯 | [red.txt](artifacts/2026-09-06/wallet-sandbox/red.txt) | 最初 20 个测试因尚无模型文件断言失败；这是结构红灯，不单独证明行为测试能抓错 |
| 正常模型 | [green.txt](artifacts/2026-09-06/wallet-sandbox/green.txt) | 23 项通过，包括 100 组精度往返 |
| 控制反例 | [mutations.json](artifacts/2026-09-06/wallet-sandbox/mutations.json) | 7/7 控制被删除后均产生行为断言失败且无测试运行错误；每个变体运行 23 项 |
| 现有钱包回归 | [existing-wallet.txt](artifacts/2026-09-06/wallet-sandbox/existing-wallet.txt) | 15 passed；1 条 Starlette/httpx 弃用警告，与本轮新增模型无关 |

新增的后 3 项属于补充回归检查，并非声称每项都经历独立测试先行红灯。7 个变异用例提供针对资金控制的负向证据。

## 规格符合性审查（先执行）

- 原“已承诺兑付”改为所有具兑付权点钻从发行时计入负债，提现冻结不重复计算；历史迁移和流动性分别定义。
- 明确间接跨用户价值转移必须传递风险；禁止用聊天正文作为风控数据。
- 固化与独立来源一致是确认数之外的门槛，模型使用注入布尔值验证拒绝路径，没有伪称查过真实链。
- 双资产中断后账本与订单回滚；审计/Outbox 仅在成功路径提交。
- 提交前暂停拒绝出款；已受理但超时保持冻结；重复调用 submit 不再调用外部提交。
- 旧快照缺失外部已完成订单时识别孤儿并保持恢复熔断，明确不自动猜测用户或补账。
- 全部新文件位于计划声明目录；现有生产代码、生成客户端、OpenAPI、签名身份和生产开关不变。

## 质量与安全审查（后执行）

模型用最小单位整数、Decimal 输入校验、SQL 参数绑定、追加账本触发器及事务实现；SQLite 数据库在内存，无运行数据库、真实地址或秘密写入仓库。外部模拟只接受固定 `sandbox-recipient`；不含网络或签名客户端。

模型只序列执行测试，“竞争订单”测试验证连续请求不能重复消费，不是多线程/多进程竞争测试。模型的外部完成状态作为可信测试输入；它不实现真实最终性证明。备份使用内存 SQL 快照，不证明跨故障域 RPO。风控只验证单账户限制和监控失效门槛，不声称已实现批次传播与滚动累计额度。提现审批是明确的模拟前提，不是 RBAC/MFA 实现。

SQL audit/outbox 表用于验证一致事务事件，不实现完整生产审计字段、投递、WORM 或权限控制。模型未实现完整充值异常悬账、费用会计、归集资源、退款/冲正、准备金配置、来源批次、真实权限与报表服务。报表测试仅验证资产级截止序号期初/净变动/期末。

因此本轮结果支持进一步设计和工程实现，不证明原应用已经符合补充设计，也不构成真实资金上线验收。

## 仓库总门禁与工具限制

总门禁 [repository-verify.txt](artifacts/2026-09-06/wallet-sandbox/repository-verify.txt) 最终退出码 0，`Verification: PASS`。其中 infra 17、Getui 28、Matrix Bot 9、业务 API/Worker 349、Flutter 边界 65 项通过，合计 468 项；业务测试另有 19 项跳过，不能计为验证通过。模板、仓库/部署策略、17 组件/330 屏 UI 契约、114 文件 AST、迁移离线生成、OpenAPI 与 Compose 渲染均通过。迁移检查是离线 SQL 生成，不代表已执行真实数据库迁移。

现有测试报告了 Starlette/httpx 和 Pydantic class-based config 弃用警告，本轮没有隐藏或修改这些警告。它们需要后续依赖兼容工作；总门禁成功不等于零警告验收。19 项跳过未在本轮解除条件，PostgreSQL 和真机能力仍按未验证处理。

新增三个 Python 文件的 AST 编译检查见 [static-check.txt](artifacts/2026-09-06/wallet-sandbox/static-check.txt)。最终模型 23 项和 7 项变异检查重新执行成功；`git diff --check` 无空白错误。Git 的 LF→CRLF 提示属于仓库行尾转换配置。

Python 3.12 环境没有安装 Ruff（`No module named ruff`），本轮不额外安装依赖，不能宣称 Ruff lint/format 通过。以 Python 编译检查、测试运行和 diff 检查补充验证，完整格式门禁仍待具备工具的环境执行。

## 下一阶段仍需验证

生产实现前：领域与 Quality/Security 批准，历史点钻全量资产负债核对，真实 Ledger 公共接口和 PostgreSQL 事务/并发测试；金融耐久日志、恢复 fencing、出款取消竞争、费用及冲正会计、批次风控和完整运营接口均需独立落地。

无需托管商参与的下一阶段可继续用持久化外部模拟与 PostgreSQL 测试上述内容。实际托管签名策略、真实链证据、移动端真机与分发、运营地区许可无法由当前离线模型代替。
