# ADR-0076：点钻人民币计价 v2、兑换关闭、汇率参考服务与储备口径修正

日期：2026-09-21。状态：**已批准（用户 2026-09-21 需求书确认全部规则）**。授权范围：实现与隔离测试；不含生产发布。替代 ADR-0010 决策 6（固定 1:1 兑换）的用户侧兑换部分与 ADR-0070 的充值自动兑换；不替代两账本独立、精度、幂等、审计、Outbox 与 append-only 不变量。

## 背景

现行模型：1 点钻 = 1 USDT 固定双向兑换（ADR-0010/0068/0070）。用户批准新计价：**1 点钻按 1 元人民币计价**；存量点钻余额数字不变（不乘除汇率、不重置）；USDT 余额仍是 USDT；外部充值付款与提现出款仅支持 USDT（经客服人工，ADR-0077）；APP 内红包/转账继续用点钻；取消用户端直接点钻/USDT 兑换；不新增 USDT P2P/USDT 红包。

## 决策

1. **计价版本化**：`caibi_pricing_version='caibi-cny-v1'`，生效时间为部署时间（服务端配置持久记录）。新旧历史订单按各自快照展示，**不重写旧订单金额或账本**。余额、冻结额、红包/转账托管金额数字一律不动。
2. **用户侧兑换写接口关闭**：新增设置 `wallet_user_conversions_closed`（默认 True）。`POST /wallet/conversions` 关闭时返回 422 `CONVERSIONS_CLOSED`（明确中文业务文案，旧客户端可见错误而非静默）；`GET` 历史与状态查询保留。已完成的 `WalletConversion` 记录原样保留。
3. **在途兑换处理**：`convert_in_session` 本就单事务原子完成（无 PENDING 状态）→ 不存在未执行/冻结的在途用户兑换。与提现绑定的内部兑换（`payout:*` 键）不属于被关闭的用户兑换：**已 REQUESTED/CLAIMED 的旧提现订单按原 1:1 报价条款继续结算**（其兑换与冻结已是既成资金事实），新报价改用汇率（见 ADR-0077）。取消退回按原转换的镜像冲正，不伪装成新兑换。
4. **充值自动兑换关闭**：`wallet_deposit_auto_conversion_enabled` 生产置 False；新增守卫——该开关与 `wallet_user_conversions_closed=True` 互斥（配置校验器强制），充值入账路径与 worker 重试任务遇关闭标志跳过兑换（USDT 余额保留），已发生的自动兑换保留痕迹。
5. **汇率参考服务（apihz）**：`GET https://cn.apihz.cn/api/jinrong/huilv.php?from=USD&to=CNY&money=10&id=…&key=…`；`FX_API_ID`/`FX_API_KEY` 从服务端环境读取（SecretStr），不进源码/前端/APP 包/日志/测试快照。
   - **按需+持久缓存 60 分钟**：`fx_rates` 表按币对（USD/CNY）单行持久化 `rate`、`fetched_at`、`expires_at=fetched_at+3600s`、供应商 `uptime`、`last_attempt_at`、`last_error_code`。用户请求时先读新缓存直接返回；过期才发起上游调用；**无用户请求零调用**（无后台定时拉取）。
   - **并发合并**：行级认领（条件 UPDATE `fetch_state idle→fetching` + 认领超时）+ 拿到认领后二次检查缓存；其余并发请求短暂等待后重读缓存，**同一过期窗口不产生请求风暴**。缓存持久化，服务重启不丢失有效期。
   - **60 分钟从本地成功获取时间起算**；供应商 `uptime` 独立保存。
   - **解析**：优先读响应 `rate` 字段；`rate` 缺失时才允许 `result/money` 推导（money=10 时 result 是 10 美元换算结果，**不得当作单位汇率**），推导须校验字段为正数并按 6 位 HALF_UP 量化。校验成功码、币种方向（from=USD,to=CNY）、正数汇率与响应结构；不符即失败。
   - **失败处理**：超时/失败**不写入假汇率（1 或 0）**、不清除最后有效报价；持久化 `last_attempt_at` 作共享退避——同一 60 分钟窗口内后续用户请求不再自动重试上游，返回过期快照并标注 `stale=true`（"过期参考"），无任何快照时返回 `FX_UNAVAILABLE`。过期报价仅作参考展示，**不作为自动资金结算依据**（结算一律用审批时点快照）。
   - 点钻→USDT 与 USDT→点钻的展示使用**同一报价快照**（同表同币对单行）；1 USDT 暂按 1 USD 估算；页面标注"参考估算，最终以客服结算为准"。
   - HTTPS 证书校验保留；含 key 的 URL 与异常一律脱敏。
6. **储备/对账口径修正（禁止跨单位相加）**：现有 `require_coverage`、`require_manual_payout_coverage`、`WalletService._reconcile` 把点钻负债数量与 USDT 负债直接相加——人民币计价后单位不同，**立即废止该加法**。改为三类数量严格区分：
   - `caibi_face`：点钻账面数量（含冻结/托管），人民币计价负债 = 数量 × ¥1；
   - `caibi_reference_usdt`：参考 USDT 估值 = caibi_face ÷ 汇率（用新鲜汇率快照；无新鲜快照时 fail-closed `RESERVE_VALUATION_UNAVAILABLE`，不假设 1:1）；
   - `usdt_obligation`：实际 USDT 义务 = USDT 负债 + 已批准未支付订单的最终 USDT 应付额。
   - `full_backing` 门禁改为：合格 USDT ≥ usdt_obligation + caibi_reference_usdt；`_reconcile` 的 USDT 托管核对改为：托管余额 ≥ usdt_obligation（点钻仅作参考估值随行报告，不并入 USDT 义务门禁）。储备行扩展 `caibi_face`/`approved_unpaid_usdt`/`valuation_rate`/`valued_at` 列（expand 迁移）供报表与快照使用。生产为 `manual_liquidity`（无金额门禁），以上公式在报表与 full_backing/测试路径生效。
7. **精度与分录**：点钻两位、USDT 六位，全程 Decimal/NUMERIC；估值变化**不产生**任何伪造充值/扣款分录——汇率只影响参考展示与人工结算金额（ADR-0077 的结算快照），账本仍按各自资产分别平衡。
8. **未变费率不擅改**：原 10 USDT 提现门槛继续按 **USDT** 口径执行，不解释为 10 点钻；红包 0.5%、最低 0.01、转账费率等全部不变。

## 迁移与回退

- `0072_fx_rates`（新表）、`0073_pricing_v2_reserve`（储备列扩展）均 expand-only。
- 回退：置 `wallet_user_conversions_closed=False` 恢复兑换入口（保留历史）；FX 服务停用仅影响参考展示与报价，不影响已结算订单；储备公式回退需 ADR 修订，不得静默恢复跨单位相加。
