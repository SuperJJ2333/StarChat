# 计划：钱包绑定/刷新/告警修复 + 红包手续费 + 充值提现美化（2026-09-17）

来源：用户 2026-09-17 五项要求。关联记录：`docs/workflow/tasks/2026-09-17-wallet-redpacket-five-items.md`。

## 范围与状态

| # | 要求 | 设计 | 状态 |
| --- | --- | --- | --- |
| 1 | 被他人登记的钱包地址无法删除；补「更改绑定」按钮（30 天限制） | 终局校验失败（`WALLET_ADDRESS_OWNED`/`ADDRESS_INVALID`/`REBIND_TOO_SOON`/`BINDING_PENDING`/`WITHDRAWAL_IN_PROGRESS`/`ACCOUNT_RESTRICTED`/`REGISTRATION_DISABLED`/`VERSION_CONFLICT`）→ 丢弃草稿、恢复可编辑、文案改为「请更换一个属于你的钱包地址」；地址框只在拿到服务端 `id` 后锁定；统一「重新填写钱包地址」出口；首页改为带文字的「更改绑定」按钮并展示 `next_rebind_at`；冷却期内先解释再禁用提交 | **完成**（commit `c9c8386a`） |
| 2 | 进入钱包闪一下「功能状态暂不可用」 | `refresh()` 不再清零已知能力；新增 `capabilitiesUnavailable`，仅当「从未拿到过能力且加载失败」时告警；加载中与刷新中沿用上次已知值（按钮也不再闪灰） | **完成** |
| 3 | 刷新按钮放顶部导航栏右侧 | 钱包根页面改为自持导航栏（`WalletPage` 不再 `embedded`），刷新进 `trailing`；AppHome 两处钱包入口去掉重复的 `CupertinoPageScaffold`+导航栏（四个钱包页面行为一致） | **完成** |
| 4 | 红包手续费 0.5%、最低 0.01、过期未领连同手续费退回 | ADR-0073（提案）+ 迁移 `0068_red_packet_fee`（expand-migrate-contract）+ `red_packet_fee()` 与转账同构 + 创建/退款分录 + 客户端展示与余额校验 | **待 ADR 批准** |
| 5 | 充值/提现页面美化（先 HTML demo） | `frontend/design-demo/wallet-deposit-withdraw-redesign-demo.html`（8 帧：首页/充值 3 态/提现 4 态），token 与 `tokens.css`、`WeChatColors` 对齐 | **完成**（demo 已获用户通过；Flutter 落地 `stepIndicator`/`statusHero`/`rowsCard`；注册表 `walletDepositPayoutRedesign20260917` + `tokenParity` 增补 `WeChatColors.warning = --color-warning`） |

## 第 4 项实施步骤（批准后）

1. 迁移 `0068_red_packet_fee`：`red_packets.fee NUMERIC(20,2)` 加可空 → 回填 `0.00` → `NOT NULL DEFAULT 0.00`；head 断言更新。
2. `redpacket/service.py`：`RED_PACKET_FEE_RATE`、`red_packet_fee()`、`_create` 分录加 `PLATFORM_FEE`、`RedPacket(fee=...)`、退款分录加 `PLATFORM_FEE: -fee` 并把手续费退回发送方。
3. 测试先行（红）：费率边界（0.01 下限/0.5%/两位 HALF_UP）、分录平衡、`PLATFORM_FEE` 追溯、退款含手续费、幂等重放不重复扣费、余额不足拒绝；改造 `test_supply_invariant.py` 的「红包无手续费」断言。
4. 客户端：`chat_red_packet_sheet.dart` 展示手续费与实扣合计、按 `total + fee` 校验余额、余额不足文案说明合计。
5. 门禁：`pytest tests/business_api`（含 redpacket/ledger/transfer）+ `flutter test` + `flutter analyze` + `scripts/verify_ui_contract.py` + `scripts/verify.ps1`。
6. 领域审查（账本/分配/幂等/审计）与质量安全审查各一次，结论写入验证记录。
7. 发布次序（待用户确认）：新客户端先行或同时；服务端先行会让旧客户端在"余额刚好够 total"时报余额不足。

## 第 5 项实施步骤（demo 通过后）

1. 注册表 `packages/ui-contracts/changliao-component-registry.json` 增加/更新钱包充值、提现页面条目（Flutter 文件、HTML tag、props、variants、states、token 映射）。
2. 按 demo 落地 `manual_wallet_page.dart` 的 `depositFields()` / `payoutFields()` 与导航栏（含 demo 中的状态：待转账/过期/报价/已结算/待核验）。
3. 现有键位保持不变（`manual-deposit-*`、`manual-payout-*`、`manual-refresh` 等），仅调整布局与信息层级，避免破坏既有 117 项钱包用例。
4. `python scripts/verify_ui_contract.py`、`flutter test test/features/wallet`、`flutter analyze`、`npm test`（frontend）与 `scripts/verify.ps1`。

## 风险

- 红包手续费是受保护变更：需 ADR 批准 + 领域与质量安全审查；旧客户端不展示手续费，存在余额校验口径差异。
- 钱包页面为非嵌入后，AppHome 不再提供导航栏；若其它入口再次包装会重复标题，已用源码断言覆盖。
- 第 1 项只清理「终局失败」草稿；网络/超时等不确定失败仍保留草稿与幂等键（避免重复提交造成重复登记）。
