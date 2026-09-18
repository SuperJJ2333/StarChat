# 提现确认订单有效期 24 小时（服务端）验证记录（2026-09-19）

任务：提现/充值的「确认订单有效期」必须是 **24 小时**，而不是 5 分钟。
上一轮已由客户端作者完成「只展示/校验服务端 `expires_at`，不本地编造时长」的部分
（见 `docs/verification/2026-09-18-wallet-recharge-withdraw-ui.md` §6.1）。本轮只改服务端，
使服务端**真正签发** 24 小时窗口。

持有范围：`services/business-api/**`、`tests/business_api/**` 与本文件。
**未提交 git**（按父 agent 指令，改动留在工作区由其统一提交）。
未改 `apps/mobile_flutter/**`、`frontend/**`、`packages/**`。

---

## 1. 变更摘要（before → after）

| # | 文件:行 | before | after | 作用 |
|---|---|---|---|---|
| 1 | `services/business-api/app/core/config.py:83` | `wallet_manual_quote_ttl_seconds: int = 86400`（原 `= 300`） | 默认签发窗口 24 小时 | 默认值即 24h；环境变量 `BUSINESS_WALLET_MANUAL_QUOTE_TTL_SECONDS` 仍可覆盖 |
| 2 | `services/business-api/app/core/config.py:139` | `1 <= wallet_manual_quote_ttl_seconds <= 3600` | `1 <= wallet_manual_quote_ttl_seconds <= 86400` | 允许上限放宽到 24h；**越界仍然抛 `ValueError('manual TRON quote/intent expiry out of bounds')`（拒绝，不 clamp，语义未变）** |
| 3 | `services/business-api/app/modules/wallet/manual_payouts.py:69` | `not timedelta(0) < self.quote_ttl <= timedelta(hours=1)` | `not timedelta(0) < self.quote_ttl <= timedelta(hours=24)` | 策略对象的硬上限从 1h 放宽到 24h；越界仍抛 `ValueError('explicit payout policy and bounded quote TTL required')` |

测试文件（新增用例，未删改既有断言）：

- `tests/business_api/wallet/test_manual_runtime.py`：+3 用例（默认 24h、上限 24h、仍可配置为更短）
- `tests/business_api/wallet/test_manual_payouts.py`：+3 用例（默认设置签发 24h 窗口、策略拒绝 >24h、超窗确认仍被拒）

生产代码改动共 **2 个文件 3 行**（`git diff --stat` 显示 `4 files changed, 81 insertions(+), 4 deletions(-)`，
其中 79 行是测试）。

---

## 2. 为什么这个窗口不能被滥用（安全论证，未弱化任何既有安全属性）

1. **过期仍然只在服务端判定，且发生在任何资金写入之前。**
   `services/business-api/app/modules/wallet/manual_payouts.py:285-286`
   `if now >= _utc(quote.expires_at): _fail('WALLET_PAYOUT_QUOTE_EXPIRED')`。
   该判断位于 `request()`（确认下单）中、`self.wallet_ledger.post(...)`（冻结资金）之前，
   也早于 `payment_pin.consume(...)`。客户端时间不参与判定。
2. **窗口不可能无界。** 两处独立上限（`config.py:139` 的 86400 秒 + `manual_payouts.py:69` 的
   `timedelta(hours=24)`）都是**拒绝式**校验：配置超过上限时进程在 `Settings` 校验/model
   构造阶段直接失败，而不是静默延长。策略对象是 frozen dataclass，构造后无法再放大。
3. **没有任何请求字段可以申请更长的窗口。** `services/business-api/app/api/manual_wallet.py:13-20`
   `AmountBody`/`PayoutQuoteBody` 使用 `extra='forbid'`，字段只有 `amount`、`expected_binding_version`、
   `funding_asset`；`PayoutBody:28-32` 只有 `quote_id`/`mfa_proof`/`payment_authorization`。
   报价时长完全由服务端策略决定，客户端无法传入 TTL。
4. **确认时对全部冻结条款重新校验，不因窗口变长而信任旧报价。**
   `manual_payouts.py:288-293` 逐项比对 `binding_id`/`binding_version`/`safety_epoch`/
   `official_config_version`/`official_address`/`policy_version`/`owner_admin_id` 以及快照摘要；
   `manual_payouts.py:296` 调 `_limits()` 用**当前**策略与 24h 滚动额度重算（`min(当前策略, 快照上限)`，
   更严的策略立即生效）；`_gate()` 仍要求绑定有效、账户未受限、提现未暂停、准备金覆盖且观测新鲜。
5. **数据库层仍有约束。** `manual_payout_models.py:14` `CheckConstraint('expires_at > created_at',
   name='ck_manual_quote_expiry')` 保证签发窗口恒为正。
6. **没有管理员可以覆盖窗口。** `app/api/manual_wallet_admin.py` 是只读投影
   （`finance_queries.py:60-71` 仅回显已存储快照），无任何修改 `expires_at` 的入口。
7. **没有后台任务会重写/延长窗口。** `services/business-worker/app/tasks/manual_wallet.py:67-79`
   只对 `CLAIMED/UNKNOWN` 订单做对账（`payouts.reconcile`），不存在「扫描过期报价并顺延」的逻辑。

净效果：窗口从 5 分钟延长到 24 小时，只延长「用户可以拿着这份**已被重新校验**的报价去确认」的时限，
不放宽任何金额、额度、绑定、安全纪元、准备金或 MFA/支付 PIN 校验。

---

## 3. 已逐处检查的调用点（file:line）

### 3.1 该设置本身的全部读取点（`wallet_manual_quote_ttl_seconds` / `quote_ttl`）

| 位置 | 作用 | 结论 |
|---|---|---|
| `services/business-api/app/core/config.py:83` | 默认值 300 → **86400** | 已改 |
| `services/business-api/app/core/config.py:139` | 上限 3600 → **86400**（越界抛错） | 已改 |
| `services/business-api/app/modules/wallet/runtime.py:65` | `ManualPayoutPolicy(..., timedelta(seconds=settings.wallet_manual_quote_ttl_seconds), ...)` —— 唯一把配置转成策略的地方 | 无需改，自动跟随 |
| `services/business-api/app/modules/wallet/manual_payouts.py:63` | `ManualPayoutPolicy.quote_ttl` 字段声明 | 无需改 |
| `services/business-api/app/modules/wallet/manual_payouts.py:69` | 策略硬上限 1h → **24h** | 已改 |
| `services/business-api/app/modules/wallet/manual_payouts.py:227` | **签发点**：快照 `expires_at=(now+policy.quote_ttl)` | 唯一的窗口签发处，跟随策略 |
| `services/business-api/app/modules/wallet/manual_payouts.py:232` | **签发点**：`ManualPayoutQuote.expires_at=now+policy.quote_ttl` | 同上 |
| `docker-compose.wallet-manual.yml:25` | `BUSINESS_WALLET_MANUAL_QUOTE_TTL_SECONDS: "${...:-300}"` | **不在本人持有范围，未改 —— 见 §7 风险 1** |
| `infra/compose/docker-compose.wallet-manual.yml:25` | 同上（同一 overlay 的副本） | **不在本人持有范围，未改** |
| `docs/runbooks/manual-tron-funding.md:21` | 文字描述「服务端报价有效期默认 300 秒」 | 不在本人持有范围，未改（文档漂移） |

全仓 grep `wallet_manual_quote_ttl_seconds|quote_ttl|QUOTE_TTL|MANUAL_QUOTE_TTL`（含 `*.py`/`*.ps1`/`.env*`）
只命中上表；`.env`、`.env.example` **没有**该变量，因此本机/生产不会通过 dotenv 覆盖成 300。

### 3.2 过期/额度/展示相关的相邻调用点（逐个确认不会截断窗口）

| 位置 | 作用 | 是否影响 24h 窗口 |
|---|---|---|
| `app/modules/wallet/manual_payouts.py:285-286` | 确认时服务端过期判定 | **保留**，是 24h 之后仍然拒绝的依据 |
| `app/modules/ledger/manual_payout_models.py:14` | `ck_manual_quote_expiry: expires_at > created_at` | 否，只要求正窗口 |
| `app/modules/wallet/manual_payouts.py:238` | `_limits()` 的 24h 滚动额度 cutoff | 否，是**金额额度**窗口，与报价有效期无关，未改 |
| `app/modules/wallet/service.py:230` | 旧 `/wallet/withdrawals` 的 24h 滚动额度 | 否，不同功能，未改 |
| `app/modules/wallet/runtime.py:59-60` | 充值意图 TTL `wallet_deposit_intent_ttl_seconds`（默认 1200 秒，上限 86400） | **否，另一个设置，明确未改**，见 §7 风险 3 |
| `app/modules/wallet/funding.py:84,106,117,156,172` | 充值意图的过期判定与签发 | 否，跟随其自身 TTL |
| `app/modules/identity/payment_pin.py:182,186` | 支付 PIN 一次性票据 300 秒 | 否，与报价有效期无关；它只在确认时一次性使用 |
| `app/api/manual_wallet.py:19-20,28-32,78-117,187-241` | 报价/下单/查询/取消/领取路由与 `QuoteView.expires_at` 字段 | 否，无 TTL 入参，出参只回显服务端快照 |
| `app/api/manual_wallet_admin.py:87-136` | 管理员只读投影 | 否，无覆盖窗口入口 |
| `app/modules/wallet/finance_queries.py:60-71` | 管理员详情回显 `quote.snapshot` | 否，只读 |
| `services/business-worker/app/tasks/manual_wallet.py:66-79` | worker 只对账 `CLAIMED/UNKNOWN` | 否，无报价过期清扫/顺延 |
| `app/modules/wallet/manual_reserve_monitor.py`（全文 grep `expire/expires_at/ttl`） | 准备金监控 | 否，不读报价 TTL |
| `app/modules/wallet/repair_payouts.py:63,122,140`、`repairs.py:242,302,357` | 人工补录预览 90 秒 | 否，另一套独立预览 TTL |

结论：全仓只有 §3.1 表中 3 行会决定窗口长度，均已按 24h 处理；没有任何隐藏的 300/3600/`timedelta(hours=1)` 截断点。
（`grep 'timedelta(hours=1)'` 剩余命中的是 `app/modules/identity/recovery.py:69` 密码重置、
`services/business-worker/app/worker.py:13` 退避上限，二者与提现报价无关。）

### 3.3 全仓 `300` / `3600` 扫描中与提现流程相邻、但**不属于**报价有效期的常量

| 位置 | 含义 | 处置 |
|---|---|---|
| `app/integrations/tron/finality.py:122,131` | TronGrid 证据新鲜度上限（`max_age_seconds ≤ 300`，运行时传 120） | 不改：这是「链上证据必须多新」的安全边界，与报价窗口无关 |
| `app/modules/identity/payment_pin.py:182,186` | 支付 PIN 授权票据 300 秒 | 不改：确认时一次性使用 |
| `app/modules/wallet/manual_reserve_monitor.py:144,146` | 观察源 pending 心跳 120 秒 / 300 秒健康阈值 | 不改：准备金监控 |
| `app/modules/wallet/binding_adapters.py:64` | 绑定校验限流 5 次/300 秒 | 不改：限流 |
| `app/modules/wallet/incidents.py:345` | 事故 300 秒分桶 | 不改：监控分桶 |
| `app/api/manual_wallet.py:140+`（`ready(...)`/`recover_closed(...)`） | 能力门禁与幂等恢复 | 不改：不含 TTL |

---

## 4. red → green 证据

统一环境（`scripts/verify.ps1:73` 相同的 PYTHONPATH）：

```powershell
$env:PYTHONUTF8='1'; $env:PYTHONIOENCODING='utf-8'
$env:PYTHONPATH="services/business-api;services/business-worker/app;D:\pythonProject\outsource\StarChat"
.venv\Scripts\python.exe -m pytest tests/business_api/wallet -k '24_hour or default_setting' -q
```

### 4.1 RED（仅加测试、未改生产代码时）

```
FAILED tests/business_api/wallet/test_manual_payouts.py::test_default_setting_issues_24_hour_quote_window
FAILED tests/business_api/wallet/test_manual_payouts.py::test_policy_rejects_quote_window_longer_than_24_hours
FAILED tests/business_api/wallet/test_manual_payouts.py::test_confirmation_after_24_hour_window_is_rejected
FAILED tests/business_api/wallet/test_manual_runtime.py::test_default_manual_quote_window_is_24_hours
FAILED tests/business_api/wallet/test_manual_runtime.py::test_manual_quote_window_maximum_is_24_hours
5 failed, 1005 deselected, 1 warning in 2.93s
```

失败原因正是目标行为缺失（不是语法/夹具错误）：

- `pydantic_core._pydantic_core.ValidationError: 1 validation error for Settings
  / Value error, manual TRON quote/intent expiry out of bounds` —— 证明旧上限 3600 拒绝 86400；
- `test_policy_rejects_quote_window_longer_than_24_hours` 在未保护的
  `ManualPayoutPolicy('test-v1', timedelta(hours=24), ...)` 处即抛错 —— 证明旧策略上限是 1 小时。

（同批次的 `test_manual_quote_window_stays_configurable_below_maximum` 在 red 阶段即通过：
600 秒本来就合法，它是防回归护栏，不是 red 用例。）

### 4.2 GREEN（应用 3 行生产改动后）

```
.....                                                                    [100%]
5 passed, 1005 deselected, 1 warning in 2.85s
```

新增 6 个用例各自证明：

| 用例 | 证明内容 |
|---|---|
| `test_manual_runtime.py::test_default_manual_quote_window_is_24_hours` | `Settings(_env_file=None).wallet_manual_quote_ttl_seconds == 86400`，且 `create_manual_wallet_runtime` 产出的 `runtime.payouts.policy.quote_ttl == timedelta(hours=24)`（默认就是 24h，不是 300s） |
| `test_manual_runtime.py::test_manual_quote_window_stays_configurable_below_maximum` | `wallet_manual_quote_ttl_seconds=600` 仍被接受 → 仍可配置、未被硬编码锁死 |
| `test_manual_runtime.py::test_manual_quote_window_maximum_is_24_hours` | `86400` 被接受；`0 / -1 / 86401 / 172800` 全部 `ValueError` → 上限就是 24h，**拒绝而非静默延长** |
| `test_manual_payouts.py::test_default_setting_issues_24_hour_quote_window` | 用**默认设置**构造策略后签发报价：`expires_at - created_at == timedelta(hours=24)`（快照字符串与数据库行都断言），且 `expires_at == created_at + 24h` |
| `test_manual_payouts.py::test_policy_rejects_quote_window_longer_than_24_hours` | `ManualPayoutPolicy(..., timedelta(hours=24))` 通过；`timedelta(hours=24, seconds=1)` 抛 `ValueError` |
| `test_manual_payouts.py::test_confirmation_after_24_hour_window_is_rejected` | 24h 策略下签发报价 → 时钟推进 `24h+1s`（同时保持会话/PIN 票据有效、准备金观测新鲜，使失败只可能来自过期判定）→ `request()` 抛 `WALLET_PAYOUT_QUOTE_EXPIRED`，且 `HOLD:alice` 余额为 0（未冻结任何资金） |

---

## 5. 测试命令与精确计数

| 命令 | 结果（exit code） |
|---|---|
| `.venv\Scripts\python.exe -m pytest tests/business_api/wallet -q` | **`995 passed, 15 skipped, 1 warning in 107.63s`**，exit 0（1010 collected） |
| `.venv\Scripts\python.exe -m pytest tests/business_api tests/business_worker -q`（与 `scripts/verify.ps1:73-74` 同 PYTHONPATH） | **`2073 passed, 58 skipped, 1 warning in 1133.99s (0:18:53)`**，exit 0 |
| `.venv\Scripts\python.exe -m pytest tests/business_api/wallet -k '24_hour or default_setting' -q` | 新增 6 用例中该过滤命中 5 个：`5 passed, 1005 deselected`（red 阶段 `5 failed, 1005 deselected`）；第 6 个 `test_manual_quote_window_stays_configurable_below_maximum` 名称不含关键字，已计入上面的 995 passed |

> 计数说明：`tests/business_api/wallet` 目录内 1010 个用例 = 995 passed + 15 skipped，0 failed，
> 与改动前相比只有新增 6 个用例、无既有用例失败或被跳过的新增。
> 注意：**不能**只把 `test_manual_payouts.py`（或它与 `test_manual_runtime.py` 两个文件）单独作为 pytest 目标——
> 该文件的共享 `core` fixture 依赖其它测试模块导入全部 ORM 模型（`Base.metadata.create_all` 需要
> `wallet_manual_deposit_cases` 等表），只收集这两个文件时会在夹具处报
> `NoReferencedTableError`（**这是改动前就存在的仓库特性**，与本次改动无关）。因此红/绿命令都以上述
> 目录或 `tests/business_api tests/business_worker` 为目标。

未运行 `scripts/verify.ps1` 全量（含 Flutter/PS 策略检查），原因：本任务只触及 business-api 配置与钱包模块，
且并发作者正在改 Flutter/契约文件；按 `docs/runbooks/mobile-delivery-workflow.md` 的证据复用规则，
本轮只跑受影响的 Python 套件 + OpenAPI 漂移检查。**该限制在 §7 声明。**

---

## 6. OpenAPI 与迁移

- **无需重新生成 OpenAPI**：`wallet_manual_quote_ttl_seconds` 既不是请求字段也不是响应字段
  （请求体 `AmountBody`/`PayoutQuoteBody` 无 TTL；响应 `QuoteView` 只有 `expires_at: string`，无默认值），
  改动后 `packages/api-contracts/openapi/liuhetong-v1.yaml` 与生成结果仍然一致。
- 实际校验（本轮运行，`scripts/verify.ps1:121-124` 的同一条命令）：
  - `py -3.12 scripts/export_openapi.py --check` → `OpenAPI contract: PASS`，exit 0（另以
    `.venv\Scripts\python.exe scripts/export_openapi.py --check` 复跑同样 PASS）
  - 若将来真出现漂移，重新生成命令为 `py -3.12 scripts/export_openapi.py`（去掉 `--check`，会覆写
    `packages/api-contracts/openapi/liuhetong-v1.yaml`）——**该文件属其他作者，本人在本轮未触碰，也不建议在无漂移时运行。**
  - 本轮 `git status --porcelain -- packages/api-contracts` 为空，契约文件在工作区未被改动。
- **无迁移改动**：`manual_payout_quotes` 表结构未变，`ck_manual_quote_expiry` 仍成立（24h 仍是正窗口）；
  Alembic 仍应只有 1 个 head（本轮未新增 revision）。

---

## 7. 剩余风险 / 未完成项

1. **⚠ 生产 compose overlay 仍会把窗口压回 300 秒（最关键的剩余项）。**
   `docker-compose.wallet-manual.yml:25` 与 `infra/compose/docker-compose.wallet-manual.yml:25`：
   `BUSINESS_WALLET_MANUAL_QUOTE_TTL_SECONDS: "${BUSINESS_WALLET_MANUAL_QUOTE_TTL_SECONDS:-300}"`。
   该文件不在本人持有范围（`services/business-api/**` + `tests/business_api/**` + 本文件），**未改**。
   只要 overlay 环境变量没有显式给出 `86400`，容器内就是 300 秒，本次服务端改动**不会在生产生效**。
   需要其持有者把它改成 `:-86400`（或部署时显式导出 `BUSINESS_WALLET_MANUAL_QUOTE_TTL_SECONDS=86400`）。
2. `docs/runbooks/manual-tron-funding.md:21` 仍写「服务端报价有效期默认 300 秒」，需其持有者同步为 24 小时（文档漂移，不影响运行）。
3. **充值的「确认订单有效期」用的是另一个设置，本轮明确未改。**
   充值意图 `wallet_deposit_intent_ttl_seconds`（默认 1200 秒，`config.py:94`；上限已允许 86400）
   与提现报价 `wallet_manual_quote_ttl_seconds` **不共享设置**，所以按需求 3「不改变其它端点 TTL」未动。
   若产品意图是**充值**确认窗口也要 24 小时，需要单独一次改动（`config.py:94` + `runtime.py:60`）
   并确认 `receipts.py:81` / `repairs.py:131` 的链上证据匹配窗口会随之从 20 分钟变成 24 小时
   （这会扩大「多久之前的链上转账可被认领」的范围，属安全边界变化，需另行评审）。
4. **部署前已签发的报价仍按旧的 5 分钟 `expires_at` 过期**（快照不可变、由服务端权威判定），
   部署后用户需要重新报价。这是 fail-closed 行为，不是缺陷。
5. **订单本身不会过期**（`REQUESTED` 订单在现有代码里没有超时清扫）：24 小时窗口只约束
   「报价 → 确认下单」，确认后的订单状态机未变。本轮未改此行为（超出任务范围）。
6. 未做真实设备/生产端到端验证（需部署后才可观测），未运行完整 `scripts/verify.ps1`（见 §5）。

---

## 8. 是否需要生产部署

**需要。** `wallet_manual_quote_ttl_seconds` 只在进程启动时被读入 `ManualPayoutPolicy`
（`runtime.py:65`，`create_manual_wallet_runtime` 于应用启动时调用），运行中的容器持有旧值 300。

最小部署范围：

1. 发布包含本次 3 行改动的 **business-api** 镜像（`services/business-api`），并重启 `business-api` 容器；
2. 同时确保 overlay 环境变量为 24h：把 `BUSINESS_WALLET_MANUAL_QUOTE_TTL_SECONDS` 显式设为 `86400`
   （或修改 §7 风险 1 的两个 compose 文件的默认值 `:-300` → `:-86400`）；
3. **business-worker 无需为本改动重启**：worker 不签发报价（`tasks/manual_wallet.py` 只做对账），
   但若同一 overlay 一起重启，其启动校验（`config.py:139`）在 86400 下同样通过；
4. 无需数据库迁移、无需改 OpenAPI、无新增依赖。

部署后验证点：新建报价的 `expires_at - created_at == 24h`；`expires_at` 之后确认仍返回
`WALLET_PAYOUT_QUOTE_EXPIRED`（HTTP 409）。
