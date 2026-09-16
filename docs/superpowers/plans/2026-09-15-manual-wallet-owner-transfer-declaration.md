# 计划：官方钱包所有者转出申报（ADR-0071）

日期：2026-09-15。ADR：`docs/adr/0071-manual-wallet-owner-transfer-declaration.md`。
范围：仅本计划所列文件；expand-only；不改既有事故/暂停/恢复语义。

## 背景

事故 9a494b09（MANUAL_UNALLOCATED_OUTFLOW）：持有者自主转出 2.00 USDT（txid `79bb6d7c…`）无任何业务记录，复核永远失败，钱包无法恢复。现有产品缺少"持有者自主转出"的受控记录通道。

## 文件所有权

新增：
- `services/business-api/app/modules/wallet/owner_transfer_models.py` — `WalletManualOwnerTransfer`
- `services/business-api/app/modules/wallet/owner_transfers.py` — `OwnerTransferService`
- `services/business-api/app/api/admin_wallet_owner_transfers.py` — 管理路由
- `services/business-api/migrations/versions/0067_wallet_owner_transfers.py` — 迁移（down 0066）
- `tests/business_api/wallet/test_owner_transfer_declaration.py` — 领域测试

修改：
- `services/business-api/app/modules/wallet/manual_reserve_monitor.py` — `_coverage` 支出分支新增申报接受路径
- `services/business-api/app/modules/wallet/safety.py` — `usdt_liability` 排除 `PLATFORM_OWNER_DRAWING`
- `services/business-api/app/modules/wallet/service.py` — `WalletLedger` 负债过滤排除 `PLATFORM_OWNER_DRAWING`
- `services/business-api/app/core/config.py` — 新开关 `wallet_owner_transfers_enabled`（默认 False）
- `services/business-api/app/api/admin.py` — 注册新路由
- `frontend/src/admin-manual-wallet-panel.js` — 面板申报入口
- `docs/runbooks/wallet-incident-recovery.md` — 恢复路径更新

## 实施步骤（测试先行）

1. **红**：新增领域测试，断言以下行为（当前全部失败）：
   - 声明后的链上支出不再触发 `MANUAL_UNALLOCATED_OUTFLOW`，监控可 PUBLISHED/REVIEWED；
   - 未声明/字段不一致的支出仍阻断（既有断言保持）；
   - 服务执行写入不可变申报行 + 平衡账本分录（`PLATFORM_CUSTODY` +金额、`PLATFORM_OWNER_DRAWING` −金额）+ 审计 + Outbox；同参数重放幂等；
   - 拒绝：非持有人、金额/收款地址/方向不符、log_index 不符、无 VERIFIED 覆盖事实、已被出款事件占用、不可信时钟、所有权声明缺失；
   - `usdt_liability` 不受申报分录影响（排除清单生效）。
2. **实现**：模型、迁移、服务（复用 repairs 的 `_authorize`/`_proof` 模式与 `wallet_ledger.post`）、监控扩展、负债排除清单、配置开关、管理路由（preview/execute/status）。
3. **面板**：admin-manual-wallet-panel 增加"所有者转出申报"区（txid/log_index/原因/声明 + 预览确认）。
4. **绿**：新测试通过；`tests/business_api` 全量回归；`scripts/verify.ps1`。
5. **文档**：runbook 增加"所有者转出申报"恢复路径；ADR 回填实施记录。

## 验收

- 事故 9a494b09 的复核在申报后可通过；未申报支出仍熔断；
- 账本分录平衡、幂等、审计、Outbox 完整；
- 用户负债与可赎回负债计算不受 `PLATFORM_OWNER_DRAWING` 影响；
- 生产部署需：迁移 0067 + 开启 `WALLET_OWNER_TRANSFERS_ENABLED=true`（API 与 worker 同步）。
