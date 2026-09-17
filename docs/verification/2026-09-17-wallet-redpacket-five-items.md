# 2026-09-17 钱包绑定/刷新/告警修复 + 红包手续费（ADR-0073）+ 充值提现美化

用户原述五项（2026-09-17）：
1. 绑定钱包页：输入已被他人登记的钱包地址后无法删除，一直提示「该地址已被其他账号登记」；正确行为应是通过不了校验并提醒更换地址；并增加「更改绑定」按钮（仍限 30 天一次）。
2. 每次进入「钱包」都会闪一下「功能状态暂不可使用…」再消失。
3. 「钱包」页刷新按钮应放到顶部导航栏右侧。
4. 红包增加手续费 0.05%（与转账相同）、最低 0.01 点钻。
5. 美化「提现」「充值」页面，先给 HTML demo 检查，风格保持一致。

用户确认（同日）：手续费按**与转账代码一致**的 **0.5%**（代码 `TRANSFER_FEE_RATE=0.005`，最低 0.01）；手续费**随未领取部分退回**；刷新按钮覆盖钱包四个页面；第 5 项**先 demo 后实现**；**批准 ADR-0073**；发布次序**新客户端先行**。

## 1. 根因与实现

### 1.1 被拒地址锁死输入框（真机 BUG）

`manual_wallet_page.dart`：
- `registerAddress()` 先用 `ManualOperationStore.begin('binding', {address, version, method:'address_only'})` **持久化**这次登记（含幂等键），再调 `POST /wallet/binding/address`；失败后草稿**从不清理**。
- `refresh()` 只在 `binding.pendingId != null || binding.version > op.version` 时清草稿；被拒地址两者都不满足 → 草稿永久保留。
- 地址输入框启用条件是 `enabled: bindingOp == null`，且 `initState` 会 `address.text = bindingOp['address']` 回填 → **被拒地址既删不掉也改不了**；「重新填写钱包地址」按钮只对签名方式（`method != 'address_only'`）显示，登记方式没有出口。

修复：新增终局失败集合 `_terminalBindingFailures`（`WALLET_ADDRESS_OWNED`/`WALLET_ADDRESS_INVALID`/`WALLET_ALREADY_BOUND`/`WALLET_REBIND_TOO_SOON`/`WALLET_BINDING_PENDING`/`WALLET_WITHDRAWAL_IN_PROGRESS`/`WALLET_ACCOUNT_RESTRICTED`/`WALLET_ADDRESS_REGISTRATION_DISABLED`/`WALLET_BINDING_VERSION_CONFLICT`），命中即 `discardBindingDraft()`（清草稿 + 释放输入框 + 丢弃 challenge）后重新抛出以显示原因；地址框启用条件改为「只有拿到服务端 `id` 才锁定」（`bindingOp?['id'] == null`）；「重新填写钱包地址」对两种方式统一提供；错误文案改为「该地址已被其他账号登记，请更换一个属于你的钱包地址。」。**网络/超时等不确定失败仍保留草稿与幂等键**（不重复登记）。

### 1.2 显式「更改绑定」按钮 + 30 天限制

首页绑定卡由「只有一个铅笔图标」改为带文字的「更改绑定 / 绑定钱包」按钮（保留 `manual-wallet-rebind` 键），并继续展示 `next_rebind_at`。绑定页新增 `rebindCoolingDown` 判断：冷却期内显示「距离上次修改未满 30 天，下次可修改时间：…」并禁用提交（先解释，而不是让用户撞服务端 `WALLET_REBIND_TOO_SOON`）。服务端 30 天规则（`binding.py::_eligible`/`activate_pending`）未改动。

### 1.3 「功能状态暂不可用」闪烁

`refresh()` 原本每次先把 `depositEnabled/payoutEnabled/...` 与 `capabilitiesKnown` 全部清零，成功才置 true；`build()` 用 `if (!capabilitiesKnown) warningBox(...)` → 每次进入/刷新都会显示一次再消失。修复：刷新期间**保留上一次已知能力**，新增 `capabilitiesUnavailable`，仅在「从未拿到过能力且本次加载失败」时为真；提示条件改为 `capabilitiesUnavailable`。加载中不再出现任何警告，能力按钮也不再闪灰。

### 1.4 刷新按钮进导航栏

钱包根页面 `WalletPage` 改为**非嵌入**（`ManualWalletPage` 自持 `CupertinoNavigationBar`，`trailing: refreshControl()`，与 `wallet_compact_test` 既有断言一致），AppHome 两处钱包入口去掉重复的 `CupertinoPageScaffold`+导航栏（否则会出现双层标题）。四个钱包页面（首页/充值/提现/绑定）现在都在导航栏右侧显示刷新。

### 1.5 红包手续费（ADR-0073，受保护变更）

- `redpacket/service.py`：`RED_PACKET_FEE_RATE = Decimal("0.005")`、`red_packet_fee(total) = max(CENT, money(total * rate))`（与 `transfer_fee` 逐字同构）；`_create` 改记 `{sender: -(total+fee), escrow: total, PLATFORM_FEE: fee}`；`_refund` 在存在未领取份额时把**未领取本金 + 手续费**一并退回发送方（全部领完的 COMPLETED 不退，手续费留在平台）。
- `redpacket/models.py`：新增持久化列 `fee NUMERIC(20,2) NOT NULL DEFAULT 0.00`；迁移 `0068_red_packet_fee`（加可空列 → 回填 0.00 → NOT NULL，expand-migrate-contract，无破坏性变更；`downgrade` 仅删列）。
- 接口：创建响应新增 `fee`（权威值）；`detail` 仅对**发起方**返回 `fee`（其他成员看不到发起方成本）。
- 客户端 `chat_red_packet_sheet.dart`：与服务端同规则的 `_fee()`（0.5%，最低 0.01，两位四舍五入）用于**展示与提交前校验**；提示行显示「手续费 x 点钻（0.5%，最低 0.01）· 实扣合计 y 点钻」；余额校验改为 `amount + fee > balance`，余额不足文案说明含手续费后的合计。

### 1.6 充值/提现美化（demo 已获用户通过）

`frontend/design-demo/wallet-deposit-withdraw-redesign-demo.html`（8 帧）为用户评审稿；Flutter 落地同一套视觉：新增 `stepIndicator`（填写金额 → 转账/确认报价 → 到账）、`statusHero`（金额/状态/有效期为主语，极端金额 `FittedBox` 缩放不溢出）、`rowsCard`（明细键值分组卡片，标签左、数值右），用于充值金额页/待转账/过期态与提现报价/订单状态；所有既有 `Key`（`manual-deposit-*`、`manual-payout-*`、`manual-refresh` 等）保持不变。

## 2. 测试与门禁

| 命令 | 结果 |
| --- | --- |
| `pytest tests/business_api/redpacket tests/business_api/ledger tests/business_api/transfer tests/business_api/test_migrations.py tests/business_api/test_wallet_release_baseline.py -q` | **71 通过 / 0 失败** |
| 新增 `tests/business_api/redpacket/test_red_packet_fee.py` | 7 通过（费率边界 0.01 下限/0.5%/与转账一致、创建扣款与 PLATFORM_FEE 追溯、持久化、全领完不退、过期退未领+手续费、取消退款、幂等重放只扣一次） |
| `test_supply_invariant.py` | 更新为「红包手续费同样进入 PLATFORM_FEE 且逐笔可追溯」，并修正原先把 `PLATFORM_RED_PACKET:`（拼写错误的科目名）断言为 0 的空断言 |
| `flutter test test/features/wallet` | **75 通过 / 0 失败**（含 9 项新增：绑定死锁 4、能力闪烁 3、导航栏刷新 1、充值/提现结构 2、红包手续费 3） |
| `flutter test test/features/matrix/chat_red_packet_sheet_test.dart` 等红包客户端用例 | **62 通过 / 0 失败** |
| `flutter analyze`（全量） | 退出码 0，`No issues found!` |
| `python scripts/verify_ui_contract.py` | `PASS (30 components, 369 screens)` |
| `flutter test`（全量） | 见任务记录（日志 `artifacts/2026-09-17/flutter-full-wallet-redpacket-five-items.txt`） |

红/绿证据：绑定死锁、能力闪烁、导航栏刷新三类用例在实现前均按预期转红（`enabled == false`、警告闪现、`manual-refresh` 不在导航栏、`更改绑定` 文案缺失）；红包手续费用例在实现前因 `red_packet_fee` 不存在而收集失败（红）。

## 3. 领域审查（红包手续费）

| 检查项 | 结论 |
| --- | --- |
| 分录平衡 | 创建 `-(total+fee) + total + fee = 0`；退款 `-unclaimed + unclaimed - fee + fee = 0`；既有 `assert_every_transaction_balanced` 覆盖并通过 |
| 金额精度 | 全链路 `Decimal` + `money()`（两位 HALF_UP）+ `CENT` 下限；无二进制浮点 |
| 幂等 | 幂等键/scope/reason_code 未变；重放返回同一单据；用例断言只扣一次手续费 |
| 退款正确性 | 未领取本金 + 手续费各退一次（断言 sender 净支出只等于被领走部分）；COMPLETED 不退款 |
| 审计与 Outbox | 复用既有 `ledger.post` 管道（审计 + `ledger.posted` 事件），未新增旁路 |
| 分配公式 | EQUAL/RANDOM/EXCLUSIVE 拆分与取整**未改动**（既有分配用例全绿） |
| 迁移 | expand-only，回填 0.00 与历史事实一致；`downgrade` 只删列，不触碰账本 |

## 4. 质量/安全审查（红包手续费 + 客户端）

| 检查项 | 结论 |
| --- | --- |
| 服务端权威 | 手续费由服务端计算并持久化；客户端 `_fee()` 仅用于展示与提交前提示，不参与记账 |
| 隐私 | `detail` 只对发起方返回 `fee`；未领取退款只回到发送方；不记录任何消息内容 |
| 失败安全 | 余额不足在事务内抛错回滚，不产生单据/分录/托管（既有用例覆盖） |
| 敏感信息 | 无新增日志、无密钥/备注/明文写入 |
| 兼容性（**需管理的风险**） | 旧客户端（≤0.3.92/2127）不展示手续费且按 `total` 校验余额：在「余额刚好够 total」时会被服务端拒绝且界面不解释。用户已选定**新客户端先行**——因此 **API 侧手续费在包含本改动的新客户端发布前不得部署**（当前仅存在于仓库，未上线） |

### 未填缺口（如实记录）

- 上述领域/质量安全审查由**执行代理按检查表自审**，未由独立审查人签署；若仓库要求独立签署，需补一次独立复核。
- 第 5 项 Flutter 落地的视觉效果未在真机核对（用户按 demo 通过，真机观感待验收）。
- 红包手续费的**生产发布**尚未执行，且按用户选择必须等新客户端先行。

## 5. 未执行项

- 未构建 APK/IPA、未部署服务端（红包手续费必须等新客户端先行；本任务只到本地实现与门禁）。
- 未真机验证（第 1–3、5 项的真机观感/手感待用户验收）。
