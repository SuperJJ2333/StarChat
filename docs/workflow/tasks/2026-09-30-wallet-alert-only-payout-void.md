# 钱包监控仅邮件告警与未广播出款撤销

## 目标、授权与所有权

- 用户要求撤销事故订单，并令所有钱包监控事故只发邮箱告警、不自动暂停钱包；用户确认该笔付款从未签名、从未广播，并批准管理员再次声明、链上复核、精确冲回及独立恢复的设计。
- 受保护变更的 [ADR](../../adr/2026-09-30-wallet-alert-only-and-unbroadcast-void.md) 与两份 [监控计划](../../superpowers/plans/2026-09-30-wallet-monitor-email-only.md)、[撤销计划](../../superpowers/plans/2026-09-30-unbroadcast-payout-void.md) 已提交隔离分支；2026-09-30 00:49 +08 时仍待用户对 ADR/计划的显式批准。
- 独立工作树：`C:\Users\Administrator\.codex\worktrees\wallet-alert-only-payout-void\StarChat`，分支 `codex/wallet-alert-only-payout-void`，文档提交 `1169a625`。本任务拥有新 ADR、规格、计划、记录及后续钱包监控、出款状态机、API、后台对应测试；根目录的大量并行未提交工作不在本任务所有权内。

## 生产只读事实

- 2026-09-30 00:25:40 +08 PostgreSQL 读回：事故 `75c01afc-29e7-416f-9609-581973994b14` 为 P0、`ACKNOWLEDGED`、异常持续；订单 `3e728fe3-7343-4036-b9a0-646e56a46457` 为 `UNKNOWN`、`EVIDENCE_UNAVAILABLE_OR_MISMATCH`，无候选交易哈希。
- 客服开始付款及订单领取均在 2026-09-29 22:45:51 +08；汇率调整后应付 10.000000 USDT。最新观察库状态 `SOURCE_MATCHED`，从领取时间后无观察到的转出事件；这是 TronGrid 单源的有界事实，不证明未广播。用户另行确认从未签名和广播。
- 当前全局提现暂停、安全限制、储备出款限制均开启。该订单关联可用 USDT 19.754820、HOLD 10.000000 的读回为一次时点快照，不授权按此直接冲回。事故邮件事件 8 条为 PUBLISHED 且各有投递回执。
- 未对生产余额、订单、事故或资金启停执行写操作。

## 验证、阶段与下一步

- 只读调查起始准确时刻未知；2026-09-30 00:49 +08 为本记录检查点。各阶段主动耗时和外部等待尚无可靠分段数据，不根据文件时间推算。
- 隔离工作树基线 `971fb50d`，文档提交前 `git diff --cached --check` 退出 0，规格到 ADR 相对链接存在。旧 main 基线定向测试：`D:\pythonProject\outsource\StarChat\.venv\Scripts\python.exe -m pytest tests/business_api/wallet/test_manual_reserve_monitor.py tests/business_api/wallet/test_wallet_monitoring.py tests/business_api/wallet/test_wallet_incidents.py -q`，`PYTHONPATH=services/business-api`，`PYTHONUTF8=1`，`PYTHONIOENCODING=utf-8`；exit 0，89 passed / 1 skipped，9.57 秒。该基线尚未导入根目录已实施的 T2 变更，不代表生产候选测试。
- 下一可执行步骤：用户批准 ADR/两计划后，对齐 T2 与生产已应用迁移至隔离工作树；按两计划写红测、实现、回归、规格/领域/安全审查，再准备隔离恢复和精确增量发布。生产撤销必须由真实钱包管理员在新后台操作中完成验证和声明；若该证明不可用，订单继续保持 `UNKNOWN`。
