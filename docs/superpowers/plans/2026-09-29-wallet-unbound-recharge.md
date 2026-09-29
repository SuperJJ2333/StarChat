# 未绑定钱包封锁新充值申请 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 没有有效 ACTIVE 私人钱包绑定的账号不能创建新充值申请，同时保留旧申请查询、恢复和同键重放，并完成钱包首页设计 A。

**Architecture:** Flutter 只负责入口和状态说明；业务 API 在充值事务内调用钱包域公开门禁，锁定绑定状态后才创建新申请。幂等已完成回执先于当前绑定与官方收款配置检查；HTML 演示复用组件注册表和设计 token。无数据库迁移。

**Tech Stack:** Flutter/Dart widget test；FastAPI、SQLAlchemy、PostgreSQL 16、pytest；原生 HTML/CSS、Node test；PowerShell 7。

---

## 基线和文件地图

批准依据：[设计规格](../specs/2026-09-29-wallet-unbound-recharge-design.md)、[ADR-0077 补充](../../adr/0077-manual-recharge-withdrawal.md)。只读生产基线为 API 镜像 `sha256:0bdf751c05015454781c24b66a0c5066ca08ce23436c232ff8aecd1ba5042993`；实施前重新核对候选与当时生产基线，不把该值当发布许可。现有 `POST /api/v1/recharge/requests` 在路由层先检查官方收款配置，服务 `submit()` 已先处理幂等再建单，但没有绑定校验；Flutter 的 CNY 分支绕过绑定。

| 文件 | 职责与所有权 |
| --- | --- |
| `services/business-api/app/modules/wallet/recharge_binding_gate.py` | 新增钱包域公开的、同事务绑定校验接口；钱包模块所有。 |
| `services/business-api/app/modules/recharge/service.py`、`services/business-api/app/api/recharge.py` | 幂等回放之后执行新申请门禁；充值模块所有。`main.py` 无需改动，避免与同时推进的 S3/0091 分支产生无关冲突。 |
| `tests/business_api/recharge/binding_fixture.py`、`tests/business_api/recharge/test_manual_recharge.py`、`tests/business_api/recharge/test_support_order_postgres.py` | 有效绑定 fixture、业务/HTTP/并发回归；更新其他直接调用 `submit()` 的 fixture。 |
| `packages/api-contracts/openapi/liuhetong-v1.yaml` | 根集成者在钱包与媒体服务端改动落地后串行导出；公开 409 绑定错误及可能扩展的诊断枚举，避免并行写同一契约文件。 |
| `apps/mobile_flutter/lib/features/wallet/manual_wallet_page.dart`、`apps/mobile_flutter/test/features/wallet/wallet_unbound_recharge_test.dart` | 禁用新充值、旧单只读入口、警示/绑定卡/余额层级；钱包 UI 所有。 |
| `frontend/src/screens/wallet-binding.js`、`frontend/tests/wallet-unbound-demo.test.mjs` | HTML 演示与 Flutter 同态；钱包演示模块所有。 |
| `frontend/src/styles/primitives.css` | 共享样式由根集成者在各模块屏幕改动完成后顺序编辑，钱包与其他 UI 模块不并行修改。 |
| `frontend/src/catalog/screens.js`、`packages/ui-contracts/changliao-component-registry.json` | 仅由根集成者顺序检查和必要时更新；不得与其他模块并行编辑。 |
| `docs/verification/artifacts/2026-09-29/wallet-unbound-recharge/` | 红绿测试、生产基线、审查和门禁证据；不存用户资料或凭证。 |

所有 PowerShell 会话先执行：

```powershell
$enc = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $enc; [Console]::OutputEncoding = $enc; $OutputEncoding = $enc
$env:PYTHONUTF8 = '1'; $env:PYTHONIOENCODING = 'utf-8'
```

### Task 1: 钱包域同事务绑定门禁

**Files:** 新建 `services/business-api/app/modules/wallet/recharge_binding_gate.py`、`tests/business_api/recharge/binding_fixture.py`；修改 `tests/business_api/recharge/test_manual_recharge.py` 中所需 fixture。

- [ ] **Step 1: 写 RED。** 在 `test_manual_recharge.py` 新增 `test_new_recharge_requires_active_binding`，用 `env` 的未绑定账号和新幂等键调用 `service.submit()`，断言 409 `WALLET_BINDING_REQUIRED`，且 `RechargeRequest`、`recharge.submitted` 审计与 Outbox 计数均未增加。再覆盖 `pending_binding_id` → `WALLET_BINDING_PENDING`、指向失效绑定/版本不符 → `WALLET_BINDING_VERSION_CONFLICT`。在共享 fixture 中显式设置隔离的 `official_config=SimpleNamespace(address='isolated-fixture-official', version='fixture-v1')`；只给现有成功路径账号创建 `WalletAddressOwner`、带激活证据的 `WalletBinding`、`WalletBindingState(version=1, active_binding_id=...)`，不给拒绝用例加跳过开关。
- [ ] **Step 2: 验证 RED。** `py -3.12 -m pytest tests/business_api/recharge/test_manual_recharge.py -q -k binding`；预期未绑定申请被错误接受或期望业务码不符。
- [ ] **Step 3: 最小实现。** 门禁只接受调用方的 SQLAlchemy `session`，不自行开事务，也不写钱包表；锁钱包状态并检查当前 ACTIVE 行和版本：

```python
class WalletRechargeBindingGate:
    def require_active(self, session, user_id: str) -> int:
        state = session.get(WalletBindingState, user_id, with_for_update=True)
        if state is not None and state.pending_binding_id:
            raise AppError(code='WALLET_BINDING_PENDING', message='钱包绑定正在变更', status_code=409)
        if state is None or not state.active_binding_id:
            raise AppError(code='WALLET_BINDING_REQUIRED', message='请先绑定钱包地址', status_code=409)
        binding = session.get(WalletBinding, state.active_binding_id)
        if (binding is None or binding.user_id != user_id or binding.status != 'ACTIVE'
                or binding.version != state.version or binding.effective_from_block is None
                or binding.effective_to_block is not None):
            raise AppError(code='WALLET_BINDING_VERSION_CONFLICT', message='钱包绑定状态已变化', status_code=409)
        return binding.version
```

  从 `app.core.errors`、`app.modules.wallet.binding_models` 导入符号。钱包已有改绑锁顺序为资金控制后绑定状态；充值仅锁绑定状态且之后不取资金控制锁。用并发用例核验这条顺序。
- [ ] **Step 4: 验证 GREEN。** 重跑 Step 2；预期对应三种 409 和零新订单/成功审计/Outbox。完成该任务后提交钱包公开接口、fixture 和测试；暂不提交整组未完更改。

### Task 2: 新申请门禁与历史幂等回放

**Files:** 修改 `services/business-api/app/modules/recharge/service.py`、`services/business-api/app/api/recharge.py`、充值测试；`packages/api-contracts/openapi/liuhetong-v1.yaml` 由根集成者在两个服务模块完成后串行生成。

- [ ] **Step 1: 写 RED。** 扩充 `test_manual_recharge.py` 的服务和 HTTP 用例：ACTIVE 且官方收款配置可用时可创建一次；随后清除 ACTIVE/设为 PENDING，同用户同键同载荷返回原 `id`、同键不同载荷仍 409；新键拒绝且三类成功写计数不变；已有单 `mine`、证据/取消保持既有语义。HTTP 未登录仍 401、跨账号读取仍 404。创建后关闭官方配置再重放同键也必须返回旧回执；关闭配置的新键必须 503。设置会抛异常的 `rate_provider` 后重放旧键，断言未调用它。按 `rg -n '\.submit\(user_id=' tests/business_api/recharge tests/business_api/wallet` 逐一检查直接提交路径：`test_manual_recharge.py`、`test_support_order_workflow.py`、`test_support_order_http.py`、`test_support_order_postgres.py`，以及 `test_money_review.py`、`test_automatic_recharge_matching.py`、`test_support_order_settlement_integration.py`；后 3 者若其共用 `core` 已 seed ACTIVE，保留并显式断言。每个成功 fixture 同时提供隔离测试用 `official_config=SimpleNamespace(address='isolated-fixture-official', version='fixture-v1')` 和真实 ACTIVE 绑定，不使用“测试模式”绕过任何新申请门禁。`test_recharge_api_contract` 创建 `app` 后在请求前给 `app.state.recharge_service.official_config` 配置同样的隔离收款信息，并设置 `settlement_enabled = True`，不改 `main.py`。
- [ ] **Step 2: 验证 RED。** `py -3.12 -m pytest tests/business_api/recharge/test_manual_recharge.py -q -k 'binding or replay or official'`；预期新 409/旧回放断言失败。
- [ ] **Step 3: 最小实现。** `RechargeService` 在 `service.py` 直接导入并默认构造 `WalletRechargeBindingGate()`，使用现有 `self.factory.begin()` 传入的 `session`，无须修改 `main.py` 的构造调用；路由删去 `official_payment_view()` 预检并直接调用原参数的 `submit()`。服务把当前事务前的 `rate_provider()` 查询移到 `_claim()` 的 `COMPLETED` 返回之后；在查重凭证和 `session.add(row)` 之前，每个真正新建的申请无条件执行：

```python
if record.status == 'COMPLETED':
    return record.response_body
official_payment = self.official_payment_view()
rate = stale = None
if self.rate_provider is not None:
    try:
        snapshot = self.rate_provider()
    except Exception:
        snapshot = None  # 参考汇率仅展示，不阻止新申请
    if snapshot is not None:
        rate, stale = Decimal(snapshot[0]), bool(snapshot[1])
self.recharge_binding_gate.require_active(session, user_id)
```

  **不新增 `require_official_payment` 参数或任何测试绕过。** 保留 `_claim()` 同账号作用域、载荷哈希、审计、Outbox 和账本零余额变更。纯格式校验可以保留在事务前；官方配置、绑定与外部参考汇率都不能先于已完成回放。新申请的 `row.official_payment = official_payment`，避免同次重复查询。参考汇率可能触发外部查询，须在持有绑定状态锁之前取得，避免把改绑锁跨网络等待；然后在同一事务内校验绑定并立即建单。
- [ ] **Step 4: 验证 GREEN 与契约。** 运行 `py -3.12 -m pytest tests/business_api/recharge/test_manual_recharge.py tests/business_api/recharge/test_support_order_workflow.py tests/business_api/recharge/test_support_order_http.py -q`；预期通过。在路由 409 响应说明中列明三个绑定码，保持原 JSON 错误结构。服务端两个模块完成后，根集成者串行运行 `py -3.12 scripts/export_openapi.py` 与 `py -3.12 scripts/export_openapi.py --check`，核对最终合并契约并单独提交。钱包实施者先提交本模块服务与测试，不并行编辑 OpenAPI。

### Task 3: PostgreSQL 事务与权限证明

**Files:** 修改 `tests/business_api/recharge/test_support_order_postgres.py`，必要时新增 `tests/business_api/recharge/test_recharge_binding_concurrency.py`。

- [ ] **Step 1: 写 RED。** 基于现有 PostgreSQL 16 隔离 fixture，在两个独立会话中用 `threading.Event` 控制交错：A 的新申请持有绑定状态锁时，B 尝试待激活改绑/失效状态；释放 A 后 B 才完成，或 B 先完成则 A 409。断言两种序列都无死锁、没有未经有效绑定提交的新单、至多一笔同键申请；不得靠 `sleep()` 推断锁行为。另断言两个用户相同幂等键各自独立，跨账号请求不可读。
- [ ] **Step 2: 验证 RED。** 在已隔离 PostgreSQL 的 `SUPPORT_ORDER_POSTGRES_URL` 环境运行 `py -3.12 -m pytest tests/business_api/recharge/test_recharge_binding_concurrency.py -q`；预期新用例因缺门禁或序列化失败。无隔离数据库时记录明确的阻塞阶段，不指向生产库运行测试。
- [ ] **Step 3: 最小调整。** 如测试暴露锁序问题，只在钱包公开门禁中调整读取/行锁策略，并让所有充值新建路径复用这一方法；不在充值模块直接改钱包表，不扩大到既有订单状态机。
- [ ] **Step 4: 验证 GREEN。** 重跑 Step 2 与 `py -3.12 -m pytest tests/business_api/recharge -q`，保留实际数据库版本、命令和退出码。完成后提交并发测试/锁序修正。

### Task 4: Flutter 钱包入口、旧申请与视觉 A

**Files:** 修改 `apps/mobile_flutter/lib/features/wallet/manual_wallet_page.dart`；新增 `apps/mobile_flutter/test/features/wallet/wallet_unbound_recharge_test.dart`。

- [ ] **Step 1: 写 RED。** 用 `MockClient` 提供 CNY pricing、UNBOUND/PENDING/绑定加载中三态，查找 key `manual-recharge-submit` 和首页 `充值` 按钮，断言均不可用且没有 `POST /recharge/requests`；ACTIVE 可提交。构造 `rechargeOp` 既有本地草稿，状态降为 UNBOUND 后同键可恢复，但不能开新单；从 `GET /recharge/requests/mine` 取得的历史仍有只读入口。断言 key `manual-wallet-binding-warning`、`manual-wallet-binding-card`、`manual-wallet-balance-value` 存在，暗色主题下卡片使用 elevated surface，警告/卡片有可读语义标签。
- [ ] **Step 2: 验证 RED。** `C:/src/flutter/bin/flutter.bat test apps/mobile_flutter/test/features/wallet/wallet_unbound_recharge_test.dart`；预期 CNY 未绑定入口可点击或新 key 缺失。
- [ ] **Step 3: 最小实现。** `canDeposit` 改为 `!busy && ready && capabilitiesKnown && activeBinding && (cnyPricing || depositEnabled)`；`openSection()` 在无 ACTIVE 时只允许明确的已有申请/历史只读恢复路径。`manualRechargeFields()` 的新申请按钮须 `rechargeOp != null || activeBinding`，终态“填写新的充值申请”也遵守 ACTIVE；`submitManualRecharge()` 在 `rechargeOp == null` 分支再次检查 `activeBinding`。首页展示“查看已有充值申请”只读入口，进入后调用现有 `loadRecharges()` 并列出历史，不把旧单视作授权新单。把原地址提示改为带警告 icon 的 `elevatedSurface` 背景框，绑定按钮改为独立 44px 以上卡片；余额数值复用 `pointsBalanceHero()` 的大号数字/缩放和等宽字体，不改变 `pointsAvailable` 来源。
- [ ] **Step 4: 验证 GREEN。** 重跑 Step 2，再跑 `C:/src/flutter/bin/flutter.bat test apps/mobile_flutter/test/features/wallet/manual_wallet_flow_test.dart apps/mobile_flutter/test/features/wallet/wallet_recharge_ui_test.dart`；预期全部通过。`C:/src/flutter/bin/dart.bat format apps/mobile_flutter/lib/features/wallet/manual_wallet_page.dart apps/mobile_flutter/test/features/wallet/wallet_unbound_recharge_test.dart` 后复跑聚焦用例；提交 UI 与测试。

### Task 5: HTML 演示、注册表一致性与验收

**Files:** 修改 `frontend/src/screens/wallet-binding.js`；新增 `frontend/tests/wallet-unbound-demo.test.mjs`。`frontend/src/styles/primitives.css` 和 `frontend/src/catalog/screens.js` 由根集成者顺序完成共享样式/注册表核对或必要编辑。

- [ ] **Step 1: 写 RED。** Node DOM 测试渲染 `walletBindingDemo({page:'home',state:'unbound'})`，断言白色语义卡、警告 icon/背景框、独立“绑定钱包”卡、放大余额，以及禁用的充值/提现；点击“查看已有充值申请”只展示示例旧单，不触发创建。已绑定态不出现未绑定警告。对应 CSS 类名使用 `c-wallet-demo__binding-warning`、`c-wallet-demo__bind-card`、`c-wallet-demo__balance-value`。
- [ ] **Step 2: 验证 RED。** 在 `frontend` 目录运行 `node --test tests/wallet-unbound-demo.test.mjs`；预期警告/卡/余额断言失败。
- [ ] **Step 3: 最小实现。** 钱包演示实施者只改 `wallet-binding.js` 的 `home` 分支：复用原 `card` 和按钮模型，增加警告盒、箭头绑定卡及 `demoBalance` 大号数值。由根集成者随后在 `primitives.css` 为上述三个类使用现有 `--color-surface-elevated`、文字/警告语义 token、既有间距和圆角变量；暗色模式随 token 变化，不写固定白色。旧单为明确标注“示例”的静态入口；演示无真实资金请求。
- [ ] **Step 4: 验证 GREEN。** 运行 `node --test tests/wallet-unbound-demo.test.mjs`、`node --test tests/group-moments-wallet-demo.test.mjs` 和 `py -3.12 scripts/verify_ui_contract.py`；预期通过。由根集成者核对组件注册表、Flutter/HTML 文案与 token 对照及 `home/unbound` 页面 URL，完成后提交演示。
- [ ] **Step 5: 总验收。** 先做规格符合性审查，再做金融领域和质量/安全审查，核对旧单、幂等、权限、审计/Outbox 与 PostgreSQL 并发证据。按 `docs/runbooks/mobile-delivery-workflow.md` 的变更影响规则和预检要求运行 `pwsh -NoProfile -File scripts/verify.ps1`，复用未变输入已完成的等价门禁，不重复构建；将命令、退出码、候选身份写到 `docs/verification/artifacts/2026-09-29/wallet-unbound-recharge/`。生产发布另按 `docs/runbooks/admin-production-workflow.md` 取得对应候选授权。

## 规格覆盖自查

新单 ACTIVE 门禁及三类 409：Tasks 1–3；旧单/幂等、配置关闭后的回放、参考汇率不阻塞旧回放、审计/Outbox：Task 2；未登录与跨账号权限：Tasks 2–3；Flutter 新入口与历史、警示、绑定卡、余额：Task 4；HTML 一致性与注册表：Task 5。无 schema、账本公式、金额精度、结算状态机改动。`business_api_client.dart`、`frontend/src/styles/primitives.css` 和 `frontend/src/catalog/screens.js` 属于其他并行模块或根集成者，钱包实施者不并行编辑。
