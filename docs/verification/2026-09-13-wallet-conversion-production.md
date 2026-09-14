# 充值自动兑换生产验收（2026-09-13）

本轮用户批准充值确认后自动按1:1转点钻，保留原有主动双向兑换，并实际处理两笔已入账历史充值。Astra负责计划、领域/安全决策、实际diff与调用链审查、独立测试和生产操作；执行代理conversion_audit/conversion_release使用显式gpt-5.6-terra，最多两个执行者。当前工作区未clone/pull/reset，按当前线上API/worker最小覆盖，没有发布其他工作区改动或移动包。

## 实际结果

2026-09-13 15:07 +08切换API及worker，自动兑换新开关在两服务开启；原有独立充值、双向兑换和其他门禁保留。API `sha256:f1c9d1eb5da438223a7c62ee24cd34283ea67422792bd1ec5f53b4d4491752dd`，worker `sha256:a1a646f43e089b8971fd23ff9c6f2b6a6a4b78b41114275ac4decffdff76b6d3`。基线分别dc41eb54、7e0e9ffc，代码manifest `329d7a9b297cba31159cc5589bbc73d4fd7f428aca9e7e795f1afc213b0483df`。schema仍0066，无迁移。其他容器ID不变。

两笔历史收据经生产preview确认属于同一用户484ce553-6452-4a1b-9d14-2f0fe30988cb、各10USDT且尚无收据绑定兑换。由配置owner57743ca0-9451-4c2e-bc38-0c229b381821执行原子事务；不是伪造用户登录，也未直接SQL修改余额或旧账本。

| 交易哈希/log | 本次点钻变化 | 兑换ID | 点钻账本ID |
| --- | --- | --- | --- |
| ab0ddd6a2723884b6ffe323ad4260aa1e25d61ecd398d5b20d35aee225a74c09 / 0 | +10.00 | 6c3ec2e9-32c1-4822-bed5-5666baf5e81c | 3552d769-a5f5-4fb1-a238-45b324e783f7 |
| 16f1f166b7b0e776f6c5529777e2eff11c9b9223b0b4ae906758f578118acbe3 / 0 | +10.00 | c7faffcf-f672-4b4a-936d-3817cb3c64e3 | 6f57d994-0b83-46d4-93be-8138e64599ca |

读回可用余额：USDT20.000000→0.000000；CAIBI11.97→31.97。StatementService.get对两笔均返回kind=deposit、amount=10.00；原充值ledger IDs未变。每笔有独立审计和Outbox事件。再次执行返回replayed=true，账本/审计/Outbox证明文件逐字一致，未重复发放。

## 实现与验证

新增收据绑定公共应用方法，正常充值、普通补录、窗口外人工补录同事务调用；内部键deposit-receipt:<receipt_id>由公开兑换入口拒绝占用。金额Decimal，兑换向下截至两位，尾数保留USDT。已有权限、账户限制、暂停、储备、人工审批不削弱。自动兑换暂时失败保留REVIEW/AUTO_CONVERSION_RETRY_REQUIRED，并修正worker筛选以重试。

- Astra针对性77项通过，后续独立进程CLI注册和真实PG补测4项通过；worker针对15项通过。Terra保留RED/GREEN证据。
- 完整verify已执行：业务后端1907通过/57跳过，新增PG测试因未设置URL出现唯一KeyError。已修正缺环境时显式skip，并以真实隔离PG地址实跑通过，不能把skip作为PG成功证明。
- 中断后的verify后半段原样续跑：移动边界70通过；UI契约30组件/368页面；API导入/AST216文件/唯一Alembic head及offlineSQL/OpenAPI/Compose通过。
- 生产备份在服务器0700目录，隔离PG16恢复：候选API101通过、候选worker2通过（真实自动兑换失败→worker重试恢复、并验证独立deposits=true/funds=false门禁）。金融表、审计和Outbox恢复前后fingerprint不变。
- 第一轮候选1个测试找错容器迁移文件路径，已修正验证工具并通过；第二轮额外旧worker测试加载新版payment_pin fixture导致14个环境错误，没有将新模型补入生产镜像。工作区15项worker回归通过，生产候选使用独立真实业务测试通过。未把不兼容套件说成通过。
- 发布后实际文件hash、运行环境开关、HTTPS JSON ready、4条匿名接口401/AUTH_REQUIRED、其他容器ID已核对。工作站通过自有loopback SOCKS保留TLS验证，健康和401通过；隧道及本地隔离PG已关闭。

## 边界与遗留

API启动后无ERROR。worker仍周期报告既有Outbox无注册消费者警告；生产只读查询显示已有wallet/ledger等历史DEAD事件（包括本次发布前的wallet.converted）。本次事件已事务持久化并验证ID/关联证据，未声称这些Outbox事件已由消费者投递完成。用户余额和账单直接读取权威账本，不依赖该异步消费。本次没有扩展为全系统Outbox治理或清除旧事件。

本轮无APP新包；真机页面刷新、真实下一笔链上充值由用户验证。已有双向兑换界面及点钻账单接口保持兼容。本次自动化成功不替代真机验收。

证据：`artifacts/2026-09-13/wallet-conversion-production/`中的astra-focused-final.log、astra-verify-full.log、astra-verify-remaining.log、candidate-images.json、rehearsal-3.log、rehearsal-ok.json、history-apply.json、history-replay.json、history-proof.json、postcheck-2.log。敏感DB备份和配置仅留服务器`/opt/starchat/releases/deposit-conversion-20260913/backup`，未下载。

回退仅还原旧镜像与配置，保留已完成兑换和审计；资金纠错走关联冲正。实际功能与两笔历史执行完成，后续只需用户真机检查及独立Outbox遗留治理。
