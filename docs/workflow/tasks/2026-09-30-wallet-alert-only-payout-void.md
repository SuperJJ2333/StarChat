# 钱包监控仅邮件告警与未广播出款撤销

## 目标、授权与所有权

- 用户要求撤销事故订单，并令所有钱包监控事故只发邮箱告警、不自动暂停钱包；用户确认该笔付款从未签名、从未广播，并批准管理员再次声明、链上复核、精确冲回及独立恢复的设计。
- 受保护变更的 [ADR](../../adr/2026-09-30-wallet-alert-only-and-unbroadcast-void.md) 与两份 [监控计划](../../superpowers/plans/2026-09-30-wallet-monitor-email-only.md)、[撤销计划](../../superpowers/plans/2026-09-30-unbroadcast-payout-void.md) 已提交隔离分支；用户随后明确回复“批准已提交的 ADR 和两份计划”，批准门槛已满足。
- 独立工作树：`C:\Users\Administrator\.codex\worktrees\wallet-alert-only-payout-void\StarChat`，分支 `codex/wallet-alert-only-payout-void`，文档提交 `1169a625`。本任务拥有新 ADR、规格、计划、记录及后续钱包监控、出款状态机、API、后台对应测试；根目录的大量并行未提交工作不在本任务所有权内。

## 生产只读事实

- 2026-09-30 00:25:40 +08 PostgreSQL 读回：事故 `75c01afc-29e7-416f-9609-581973994b14` 为 P0、`ACKNOWLEDGED`、异常持续；订单 `3e728fe3-7343-4036-b9a0-646e56a46457` 为 `UNKNOWN`、`EVIDENCE_UNAVAILABLE_OR_MISMATCH`，无候选交易哈希。
- 客服开始付款及订单领取均在 2026-09-29 22:45:51 +08；汇率调整后应付 10.000000 USDT。最新观察库状态 `SOURCE_MATCHED`，从领取时间后无观察到的转出事件；这是 TronGrid 单源的有界事实，不证明未广播。用户另行确认从未签名和广播。
- 当前全局提现暂停、安全限制、储备出款限制均开启。该订单关联可用 USDT 19.754820、HOLD 10.000000 的读回为一次时点快照，不授权按此直接冲回。事故邮件事件 8 条为 PUBLISHED 且各有投递回执。
- 未对生产余额、订单、事故或资金启停执行写操作。

## 验证、阶段与下一步

- 只读调查起始准确时刻未知；2026-09-30 00:49 +08 为本记录检查点。各阶段主动耗时和外部等待尚无可靠分段数据，不根据文件时间推算。
- 隔离工作树基线 `971fb50d`，文档提交前 `git diff --cached --check` 退出 0，规格到 ADR 相对链接存在。旧 main 基线定向测试：`D:\pythonProject\outsource\StarChat\.venv\Scripts\python.exe -m pytest tests/business_api/wallet/test_manual_reserve_monitor.py tests/business_api/wallet/test_wallet_monitoring.py tests/business_api/wallet/test_wallet_incidents.py -q`，`PYTHONPATH=services/business-api`，`PYTHONUTF8=1`，`PYTHONIOENCODING=utf-8`；exit 0，89 passed / 1 skipped，9.57 秒。该基线尚未导入根目录已实施的 T2 变更，不代表生产候选测试。
- 下一可执行步骤：对齐 T2 与生产已应用迁移至隔离工作树；按两计划写红测、实现、回归、规格/领域/安全审查，再准备隔离恢复和精确增量发布。生产撤销必须由真实钱包管理员在新后台操作中完成验证和声明；若该证明不可用，订单继续保持 `UNKNOWN`。

## 执行检查点：2026-09-30 01:10 +08

- 用户批准后开始实现；监控、出款核心、授权 API/观察证据分别拥有不重叠文件，主任务拥有前端、文档、发布与整合。根目录 T2 的告警邮件、T2 展示及测试逐文件导入工作树；0089–0091 迁移按原内容导入，均未改根目录。
- 前端新增 `UNKNOWN` 且无候选交易的官方钱包拥有者声明表单，显式勾选未签名与未广播，显示最终应付金额，网络结果未知时保留原幂等键；`VOIDED` 有独立终态文案。新增两条测试先因缺失表单与状态文案失败，随后通过。`node --test frontend/tests/wallet-incident-workflow.test.mjs frontend/tests/manual-wallet-panel.test.mjs`：64 passed、0 failed。所有事故展示已改为邮件告警、无新增自动暂停，历史暂停仍须独立处理。
- 2026-09-30 01:10 +08 生产只读 `docker compose ps`：business-api 镜像 `sha256:fadabb52cd61c078599ceda2544cea6f34dd85b0dbc0b6c5d276c5d3a96ab7dd`、business-worker 镜像 `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf`，两者 healthy；尚未部署或执行订单写操作。

## 执行检查点：2026-09-30 14:04 +08

- M1–M4 监控邮件政策与 V1–V5 撤销功能已实现、审查和生产发布，证据见 [监控发布](../../verification/2026-09-30-wallet-monitor-email-only.md)、[撤销演练](../../verification/2026-09-30-unbroadcast-payout-void.md)。实际生产 head=0093；API902eaefc、worker90d7fb74，切换 13:59:33 +08，两角色 healthy/0 restart，其余28容器不变，6静态哈希一致。
- 13:07 起继续处理实现审查、独立验证修复、PG 恢复/并发、最终镜像和发布；13:59:33 完成切换，14:04 读回。此前时段缺可靠分段时间；不推算主动时长或重复累加并行测试。全后端30m04.13s与 Flutter3m20s是工具自身耗时，返工细节见证据。
- 原单14:04仍UNKNOWN/version1，无候选；原事故ACKNOWLEDGED/version9，异常持续，当前预检READY。监控新周期继续扫描，但控制epoch2774保持不变、无新增自动暂停；原有三项暂停仍true。8历史告警有8SMTP回执。
- V6真实订单撤销和V7事故结案/独立恢复尚未完成。浏览器控制工具两次超时，无法代用真实管理员会话；已经请求用户在新后台以本次独立证明执行，然后反馈结果。没有生产财务写入或直接SQL改状态。下一步：收到用户操作反馈，先只读核对VOIDED/补偿/审计/Outbox，再走事故处理及独立恢复。

## 用户反馈修正：2026-09-30 14:21 +08

- 用户看到的是客服提现订单的哈希提交/链上查询，原撤销表单位于官方钱包而缺少跨页面入口。新增 UNKNOWN 订单“前往官方钱包核对并撤销”，仅管理员展示，通过既有导航回调进入钱包授权边界；不依赖客服租约、不执行财务写。
- 红：新增入口测试缺按钮失败（7 pass/1 fail）；绿：8 pass，前端全量 320 pass/0 fail，1.90s。规格/领域先 PASS，质量/安全随后 PASS。生产 live admin-home 语法检查通过。
- 14:21:13 精确发布三个静态文件；基于实际生产源码保留既有钱包工作区。版本 `20260930-wallet-void-entry`，发布前后 SHA256、回退备份、全部运行容器未变；服务器 HTTPS 三文件哈希一致，工作站 HTTPS 面板哈希一致。证据在 artifacts/2026-09-30/entry-deployment-proof.json、frontend-entry-fix.log。
- 原订单实际撤销、事故结案、独立恢复仍待管理员执行；下一步用户刷新后台，在本单新入口进入官方钱包的“人工出款”，查看本单并提交未广播撤销，再只读核对结果。
