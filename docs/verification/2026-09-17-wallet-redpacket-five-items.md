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
| `py -3.12 scripts/export_openapi.py --check` | `OpenAPI contract: PASS`（红包创建路由未声明 response_model，spec 无漂移） |
| `flutter test`（全量） | **2848 通过 / 0 失败**，日志 `artifacts/2026-09-17/flutter-full-wallet-redpacket-five-items.txt` |
| `pwsh -NoProfile -File scripts/verify.ps1`（仓库合并门禁，commit `c69e55c2`） | **`Verification: PASS`（退出码 0）**：Repository policy / Deployment policy / TemplateTools PASS；Infra render 143；Getui bridge 28；Matrix Bot 9；**Business API and Worker 1933 通过 / 58 跳过 / 0 失败**（修复前 1925 通过 + 5 失败）；Flutter boundary 70；UI contract PASS；API import PASS；AST parse 219 文件；Alembic 单 head + 离线 upgrade PASS；OpenAPI PASS；Compose render PASS。日志 `artifacts/2026-09-17/verify-wallet-redpacket-five-items.txt` |

**候选 commit 说明**：本文档全部结论（含 `verify.ps1` 全绿）对应 commit `c69e55c2`（其父 `a01055fc` 是独立审查当时看到的
版本，**不含**测试修复且自身门禁为红；审查指出的这一点已通过 `c69e55c2` 解决）。发布依据请使用 `c69e55c2` 或其后继。

UI 交付契约（`ui-demo-delivery` 技能第 2/5 步）：注册表新增 `walletDepositPayoutRedesign20260917` 修订块
（flutter 文件、HTML demo 路径与 8 个 demo id、20 个状态、token 映射、行为说明、红包手续费边界与验证摘要），
并新增 `tokenParity` 条目 `WeChatColors.warning = --color-warning`；实现侧把原先两处硬编码
`Color(0xFFFA9D3B)` 改为复用既有 `WeChatColors.warning`，demo 同步改用 `--color-warning`（不新造 token）。
`Figma 已退役：本次变更仅更新 HTML demo（frontend/design-demo/wallet-deposit-withdraw-redesign-demo.html）`。

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

- 第 5 项 Flutter 落地的视觉效果未在真机核对（用户按 demo 通过，真机观感待验收）。
- 红包手续费的**生产发布**尚未执行，且按用户选择必须等新客户端先行。

## 6. 独立审查（由独立子代理执行，非自审）

自审结论已被独立复核取代/补充。执行代理另起两个独立上下文的子代理分别做领域（账本/资金正确性）与质量安全审查，
只读、不得修改仓库。

### 6.1 领域审查结论：**APPROVE-WITH-RESERVATIONS**（7/7 检查 PASS）

费率公式（与 `transfer_fee` 逐字同构、无浮点）、分录平衡与 `PLATFORM_FEE` 逐笔可追溯、退款语义（状态守卫 +
持久化 `packet.fee`、全额退一次、全领完不退）、幂等与并发（`lock_account` 串行 + 唯一约束）、迁移
（expand-only、回填 0.00 与历史事实一致、单 head）、分配公式与领取路径零改动、审计/Outbox 无旁路——全部 PASS。

其提出的问题与处理：

| 编号 | 内容 | 处理 |
| --- | --- | --- |
| D1（中） | `tests/business_worker/test_redpacket_expiry.py` 仍断言旧余额 `4.00`，含手续费后应为 `3.99` | **已修**：改为 3.99 + `PLATFORM_FEE=0.01` + 两个 escrow 断言 + 二次运行不得重复退款 |
| D2（低） | 缺少 worker 过期路径的手续费账本断言 | **已补**：同上（该文件现在覆盖 worker 驱动的手续费退款与幂等） |
| D3（低） | 缺少 API 级「余额刚好等于 total 但不足 total+fee」用例 | **已补**：`test_redpacket_balance_check_includes_the_fee`（10.00 余额：total=10.00 → 422 且零副作用；total=9.95+0.05 → 201 且余额归零） |
| D4（低） | 仓库内已有三处 0.005 费率实现，存在将来漂移风险 | 记录为后续重构项（本次不合并，避免扩大受保护变更范围） |
| 缺测试 | 手续费交易的审计/Outbox 断言 | **已补**：`test_create_fee_transaction_carries_audit_and_outbox`（actor=发送方、reason=RED_PACKET_CREATE、审计 1 条、Outbox 1 条） |
| 缺测试 | 迁移回填/降级的真实库验证、Postgres 同键并发创建 | 未做：属发布前置项（当前未部署），已列入待办 |
| R3 | 部分领取后过期会把**全额**手续费退回（平台对 99% 已领完的红包不收手续费） | 与转账逐字一致且符合 ADR 决策 4；仍需用户确认商业意图（见待确认项） |
| R4 | 退款手续费以负数进 `PLATFORM_FEE`，报表需按 `reason_code` 区分红包/转账 | 已在 ADR 与报表口径中记录 |

### 6.2 质量安全审查结论：**APPROVE-WITH-RESERVATIONS**（8 项检查：6 PASS / 3 CONCERN 型）

服务端权威（红包金额无 fee 入参、客户端仅提示）、金额解析（服务端 Decimal + HALF_UP + 下限）、迁移
（expand-only、单 head）、失败安全与幂等（事务内回滚、重放返回既有单据与既有 fee）、无新增秘密/`latest` 依赖
——均 PASS。其提出的问题与处理：

| 编号 | 内容 | 处理 |
| --- | --- | --- |
| **P1（流程，阻塞）** | 审查的 commit `a01055fc` **不含**当时的测试修复（修复还只在工作区），因此该 commit 自身门禁是红的；而验证文档已声称修复完成 | **已修**：修复已提交为 `c69e55c2`，并在该 commit 上重跑门禁；本文档的结论以 `c69e55c2` 为准 |
| P2（中） | 授权弹窗只对转账显示手续费，红包走 `null` 分支 → 新客户端在 PIN 授权页看不到红包手续费 | **已修**：`chat_payment_flow.dart` 两种动作统一显示手续费，并抽出 `chatPaymentFeeOrNull` 作为**唯一**手续费实现（BigInt、无浮点），红包面板改为复用它（删除了此前的 double 估算与重复公式）；新增 `chat_payment_fee_test` |
| P3（中） | 服务端 `RED_PACKET_BALANCE_INSUFFICIENT` 文案不提手续费，与 ADR-0073 §5 不符 | **已修**：`api/redpacket.py` 现在返回「含 0.5% 手续费 x 点钻，需合计 y 点钻」，并在 API 用例中断言该文案 |
| P4（低） | 缺少「非发起方 detail 的 fee 为 None」隐私断言 | **已补**：`test_red_packet_fee_is_visible_only_to_the_sender` |
| P5（低） | 客户端不确定结果的幂等键只存在于内存 intent（重启/关闭后重试会生成新键 → 可能第二个红包） | **既有行为**，非本次引入；记录为后续项（不在本次受保护变更范围内），发布前需知悉 |
| P6（低） | Postgres 同键并发创建、真实库迁移回填/降级演练缺失 | 属**发布前置项**（当前未部署），已列入待办 |

发布前置（审查要求，均未执行，因本次不部署）：① 提交测试修复并重跑全量门禁（本轮完成）；
② 新客户端达到更新覆盖后再开启服务端扣费；③ 服务端文案含合计（已改）；④ 生产形态 Postgres 副本上演练
`upgrade`/`downgrade` 与回填；⑤ 补 P5/P6 两项测试；⑥ 确认 R3（部分领取后过期退全额手续费）的商业意图。

### 6.3 审查对本文档证据的影响（重要）

领域与质量安全审查都是在 `a01055fc` 上做的，并指出该 commit 不含测试修复；本文档第 2、7 节所述的红绿与
「修复后定向重跑」现已在 **`c69e55c2`** 上重新执行并记录（后端受影响套件 93 通过 / 客户端 91 通过 /
`flutter analyze` 无问题 / `verify.ps1` 见第 7 节）。任何以此仓库为发布依据的人应当以 `c69e55c2`（或其后继）
为候选，而不是 `a01055fc`。

## 7. 门禁返工记录（必须告知）

首次 `pwsh -NoProfile -File scripts/verify.ps1` 在 **Business API and Worker tests** 处失败：
`5 failed, 1925 passed, 58 skipped`，全部与本次手续费改动相关（旧断言仍按「红包免费」写死）：

| 失败 | 原因 | 处理 |
| --- | --- | --- |
| `test_payment_pin.py::test_redpacket_enforces_pin` | 断言余额 `9`（10−1.00） | 改为 `8.99`（10−1.00−0.01，并注明重放不二次扣费） |
| `test_payment_pin_api.py::test_real_create_api_pin_gate_bound_authorization_and_retry`（×3 参数） | 三元断言把红包当免费（`'99'`） | 统一为 `98.99`（红包与转账都是 100−1.01） |
| `test_redpacket_expiry.py::test_expiry_task_refunds_due_packets_only` | worker 过期退款断言 `4.00` | 改为含手续费退款的 `3.99` 并补幂等与 escrow 断言 |

修复后定向重跑：`pytest tests/business_api/redpacket tests/business_api/test_payment_pin.py
tests/business_api/test_payment_pin_api.py tests/business_worker/test_redpacket_expiry.py -q` → **61 通过 / 0 失败**。

## 8. 未执行项

- 未构建 APK/IPA、未部署服务端（红包手续费必须等新客户端先行；本任务只到本地实现与门禁）。
- 未真机验证（第 1–3、5 项的真机观感/手感待用户验收）。
