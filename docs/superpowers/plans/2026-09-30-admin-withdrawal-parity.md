# 管理员提现与充值一致性实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 统一充值/提现后台界面，管理员专属提现，实时汇率预览及安全取消。

**Architecture:** 复用人工出款领域和账本公开接口；新增提现专属鉴权，保留充值客服授权。后台预览使用整数定点计算，服务端绑定最终报价；未广播撤销复用 VOIDED，已广播仅复核。

**Tech Stack:** FastAPI / SQLAlchemy / PostgreSQL / Python Decimal；原生 JavaScript HTML 后台及现有 UI registry。

**Spec:** [正式设计](../specs/2026-09-30-admin-withdrawal-parity-design.md)；[ADR](../../adr/2026-09-30-admin-withdrawal-parity.md)。

状态：待用户批准；推荐本会话主代理顺序实施，领域/规格评审后进行质量安全评审。用户尚未选择执行方式。

## Global Constraints

- 点钻 2 位小数；USDT 6 位小数；汇率最多 6 位小数，Decimal ROUND_HALF_UP。
- 仅 SUPER_ADMIN 且 ID 等于 `wallet_manual_owner_admin_id` 可处理后台提现；充值客服权限保留。
- 仅从未签名、从未广播才符合 VOIDED 条件；TronGrid 未查到到账不构成退款证据。
- 已开始实际付款指令、候选哈希、UNKNOWN、终态均禁止调价。
- 金融写保留独立验证、幂等、actor/reason/audit/Outbox、追加平衡账本；无跨模块直接表写入。
- 临时证据只放 `docs/verification/artifacts/2026-09-30/admin-withdrawal-parity/`；全部终端使用 pwsh.exe、UTF-8 无 BOM。

## Review Focus

1. 客服已持有领取 token 后被收紧权限，直接 API 调用必须立即拒绝（Task 1）。
2. 旧客服单已出付款指令、尚无哈希，不得被当成未执行单接管重付（Task 2）。
3. 管理员浏览器休眠后恢复，旧基准、旧版本或旧权限不可提交（Task 3、4）。
4. 已广播交易延迟到账与停止复核同时发生，不得退款或阻断合法结算（Task 2、4）。
5. 原先汇率调低导致部分 USDT 已释放并被使用，撤销必须原子拒绝而非平台补足（Task 4）。

## Task 0：批准、设计评审和基线

**Files:** 本设计、ADR、计划、`docs/workflow/tasks/2026-09-30-admin-withdrawal-parity.md`。

- [ ] 用户审阅批准文档并选择本会话顺序实施或分任务代理实施。
- [ ] Domain 设计评审检查汇率方向、冻结调整、原兑换冲回和到账/退款互斥；记录真实结论。
- [ ] Domain 通过后做 Quality/Security 设计评审，覆盖实时 RBAC、负责人边界、独立证明及旧客户端兼容。
- [ ] 创建/选择本任务隔离工作树，记录 Git 基线、目标源码 SHA、生产当前镜像/配置/迁移和静态 SHA。检查 deeper AGENTS 与 CodeGraph 是否存在。

## Task 1：提现专属管理员授权

**Files:** 新增 `services/business-api/app/modules/identity/payout_admin_auth.py`；修改 `app/modules/wallet/support_payout.py`、`app/api/support_payout.py`、`app/modules/wallet/manual_payouts.py`、`app/api/manual_wallet.py`（以上相对 services/business-api）；测试新增 `tests/business_api/wallet/test_payout_admin_policy.py`，扩展 `test_support_payout.py`、`test_manual_wallet_api.py`。

**Interfaces:** 新增 `PayoutAdminSessionAuthorizer(settings, factory, clock)`，提供 `require(*, claims)` 及 `authorization(*, claims)`，后者返回与现有资金引擎兼容的事务内 authorize/final-check callable。所有后台提现读写采用此策略；充值继续使用原 SupportOrderSessionAuthorizer。

- [ ] 写失败测试 `test_finance_staff_and_stale_claim_token_cannot_operate_payout`，断言所有客服角色、非负责人管理员、普通客户端 scope 被拒绝且账本/Outbox 无变化；加 `test_finance_staff_can_still_process_recharge`。
- [ ] 运行 `.venv/Scripts/python.exe -m pytest tests/business_api/wallet/test_payout_admin_policy.py -q`，记录因现行客服授权导致的预期失败。
- [ ] 实现专属鉴权，覆盖所有人工入口及领域路径，锁后/提交前重新验证角色、会话、负责人、资金保护和独立操作证明；禁止客户端自行声明角色。
- [ ] 运行新增策略测试及上述两个现有测试文件，记录通过数、退出码；提交本任务文件。

## Task 2：接管、取消与停止复核

**Files:** 修改 `services/business-api/app/modules/wallet/support_payout.py`、`services/business-api/app/modules/wallet/manual_payouts.py`、`services/business-api/app/api/support_payout.py`、`services/business-api/app/api/manual_wallet_operations.py`；新增 `tests/business_api/wallet/test_payout_admin_cancellation.py`；扩展 `tests/business_api/wallet/test_manual_payout_void_support.py`、`tests/business_api/wallet/test_support_payout_postgres.py`。

**Interfaces:** 新增 `SupportPayoutService.takeover_unstarted(*, claims, order_id, expected_version, reason_code, idempotency_key)`；新增 `cancel_unstarted(..., authorize)`（同样参数，authorize 为独立操作验证 callable）；新增 `stop_for_review(*, claims, order_id, expected_version, reason_code, idempotency_key)`。分别映射 POST `/{order_id}/takeover-unstarted`、`/cancel-unstarted`、`/stop-for-review`，沿用已有 management prefix。未广播退款继续走既有 `void_unbroadcast`，不复制退款算法。

- [ ] 写失败测试：`test_takeover_invalidates_old_lease_without_erasing_claim_history`；`test_started_without_txid_cannot_be_taken_over_or_refunded`；`test_stop_for_review_does_not_refund_and_late_arrival_still_settles`；`test_cancel_unstarted_reverses_conversion_once`。断言资金、历史、audit、Outbox 及终态。
- [ ] 运行新取消测试文件及 void support 文件，记录预期红。
- [ ] 实现三个公开动作，订单锁/版本重检；未执行退款复用钱包公开接口；停止复核维持/进入 UNKNOWN，禁止新指令与调价，持续链上核验。返回可选 `allowed_actions` 与 `cancellation_block_reason`。
- [ ] 新管理资金动作绑定独立验证到订单、版本、reason 与幂等 payload；不得使用仅领取 token 代替证明。事务内验证扫描/证据和原兑换可冲回条件。
- [ ] 聚焦绿后运行真实 PostgreSQL 旧领取/接管/取消并发测试；提交实现、合同和测试。

## Task 3：统一样式及汇率预览

**Files:** 修改 `frontend/src/admin-support-payout-panel.js`、`admin-recharge-panel.js`、`admin-home.js`、`admin-api.js`；新增 `frontend/src/admin-settlement-preview.js`、`frontend/tests/admin-payout-parity.test.mjs`；扩展 `admin-recharge-panel.test.mjs`；更新 `frontend/src/catalog/` 中实际充值/提现对应 demo、`packages/ui-contracts/changliao-component-registry.json`。只修改实际引用的样式，复用现有 recharge classes/tokens。

**Interfaces:** `previewWithdrawal(fundingAmount, finalRate)` 返回六位 USDT 字符串或 null；`adjustReferenceRate(referenceRate, percent)` 返回六位汇率字符串或 null，percent 为 95/99/100/101/105。纯整数定点模块；新增 admin-api methods 与 Task 2 三个路由对应。保留现有模块导出以兼容引用。

- [ ] 写红测试：200.00/7.000000 为 28.571429；+5% 为 7.350000、27.210884；连续点击仍相对基准；缺失/过期基准禁用；手工有效输入可预览；非法/大数/USDT 本金旧单不误算。
- [ ] 写红交互测试：客服无提现入口；独立验证、取消确认、停止复核说明；刷新保留草稿和已保存汇率；过期版本/休眠恢复停止修改；等待、失败、关闭返回及重复点击不重复提交。
- [ ] `node --test frontend/tests/admin-payout-parity.test.mjs frontend/tests/admin-recharge-panel.test.mjs`，记录真实预期红。
- [ ] 实现共享预览模块、五个快捷按钮、一致字段/弹窗与管理员文案。使用服务端 allowed_actions；付款指令绑定最新最终报价，错误保留草稿并明确原因。
- [ ] 跑上述测试到绿；补 demo/registry 对应状态；执行 `python scripts/verify_ui_contract.py` 与 `npm test`（frontend 目录），记录桌面和窄屏截图、视觉对齐及功能证据；提交。

## Task 4：资金、并发、合同及独立评审

**Files:** 扩展 `tests/business_api/wallet/test_manual_payout_void_postgres.py`、`test_support_payout_postgres.py`、`test_manual_payout_rate.py`；更新仓库现有 OpenAPI 生成物；新增 `docs/verification/2026-09-30-admin-withdrawal-parity.md`。

- [ ] 测试取消对到账结算、调价、租约接管并发；仅一个合法结果，余额按每资产平衡，无重复 Outbox/冲回。
- [ ] 测试角色撤销、会话失效、证明过期在锁等待后拒绝；测试迟到链上交易、扫描不可用/过期/疑似匹配/候选哈希拒绝退款。
- [ ] 测试调整释放余额已使用时退款原子拒绝；测试旧客户端 VOIDED 投影、旧 USDT 单及既有用户申请/取消接口。
- [ ] 聚焦及集成通过后，预检 verify 环境，再运行 `pwsh.exe -NoProfile -File scripts/verify.ps1`；记录所有失败/跳过及是否影响候选，不声称未运行门禁通过。
- [ ] 先规格/Domain 实施评审，再 Quality/Security 实施评审；修复反馈并只复测受影响输入；提交证据及合同。

## Task 5：最小发布与验收

**Files:** 本任务 verification、workflow task；服务器私有发布清单及回退脚本。

- [ ] 复核实时生产漂移，用现行 API 镜像最小覆盖本任务清单；worker 无变化不重建。保留 OTP、参考估值、下载线路、续期协议等已发布功能。
- [ ] 冻结备份及安全回退方案；不破坏账本扩展，不自动恢复旧客服资金写权限。需要迁移时使用 expand-only 并先证明恢复。
- [ ] 候选镜像合同/权限拒绝/健康门禁及隔离 PG 恢复通过后按批准范围发布；静态依赖按顺序原子替换并更新缓存版本。
- [ ] 服务器、工作站分别验证资源哈希、JSON 健康、客服拒绝、管理员页面、其他容器不变及无新增错误。
- [ ] 实际退款须由管理员真实会话独立确认；不伪造会话或直接 SQL 退款。记录订单、账本、事故和资金启停分别的状态，不把 UI 测试当生产退款证据。
- [ ] 按 W1–W6 更新验收台账、耗时和下一步；列出未完成反馈，不提前宣布资金已退或整体完成。

## 本次实施结论（2026-09-30）

用户批准本计划、设计和 ADR，选择主代理顺序实施。Task 0–5 已按最终镜像和生产证据交付；详细结果与门禁限制见 [验收](../../verification/2026-09-30-admin-withdrawal-parity.md)。实际退款不属于自动发布动作，仍须独立确认。

接口裁决：复用当前已发布的 `/takeover` 公共动作处理未开始领取和已开始的证据接管，不新增含义重复的 `/takeover-unstarted` 路由；执行时严格区分是否已开始，保留原付款人历史。现行 0094 准备只存报价，开始付款才调平冻结；取消按实际冻结与原兑换处理。上述裁决不扩大取消边界。

新覆盖包括历史调整释放资金已花掉时的撤销原子拒绝，最终镜像隔离 PostgreSQL 追加 1 项通过。完整 verify 的缺 .env 与历史首页 iOS 测试失败已逐项记录，无未经验证的整体通过声明。
