# 验证记录：点钻人民币计价 / 人工出入款 / 红包抽成 / 群主冷却 / 手机号注册（2026-09-21）

任务：[2026-09-21-pricing-auth-redpacket-program](../workflow/tasks/2026-09-21-pricing-auth-redpacket-program.md) ·
计划：[2026-09-21-pricing-auth-redpacket-group-program](../superpowers/plans/2026-09-21-pricing-auth-redpacket-group-program.md) ·
ADR：0075 / 0076 / 0077 / 0078 / 0079

**授权边界：本次仅实现 + 隔离测试。未部署生产、未发生任何真实出款、未修改生产数据、未发布任何客户端。**

## 一、完成状态总表（严格区分层级）

| # | 事项 | 已实现 | 已测试 | 待真机 | 未发布 |
| - | ---- | ------ | ------ | ------ | ------ |
| 1 | FX 汇率参考服务（apihz，60min 持久缓存/并发合并/失败退避/脱敏） | ✅ | ✅ 18 项 | — | ✅ 未发布 |
| 2 | 点钻计价 v2：用户兑换写接口关闭（CONVERSIONS_CLOSED） | ✅ | ✅ | — | ✅ 未发布 |
| 3 | 充值自动兑换/在线自动充值关闭（守卫+配置校验器） | ✅ | ✅ | — | ✅ 未发布 |
| 4 | 储备/对账跨单位加法废止 + 三类数量口径（caibi_face / reference / usdt_obligation） | ✅ | ✅ 9 项 | — | ✅ 未发布 |
| 5 | 红包群主抽成 0.1% + 满 10 人群主免手续费（COMPLETED 一次性结算/退款 FORFEITED/worker 兜底） | ✅ | ✅ 42 项 | — | ✅ 未发布 |
| 6 | 业务群注册表 + 群主转让冷却（30×24h UTC / 并发单赢家 / 任期迁移 / desync） | ✅ | ✅ 35 项 | — | ✅ 未发布 |
| 7 | 人工提现：汇率快照报价 + USDT 应付折算 + adjust-rate 客服调价 + 镜像冲正 | ✅ | ✅ 7 项（含 63 项既有回归） | — | ✅ 未发布 |
| 8 | 人工充值：客服目录 + 充值申请单 + 凭证防重 + 既有财务服务入账 + 审计/Outbox | ✅ | ✅ 7 项 | — | ✅ 未发布 |
| 9 | 手机号注册/短信 OTP 登录/两步换绑/隐私搜索（服务端 + API） | ✅ | ✅ 13 项 + 既有身份回归 280 项 | — | ✅ 未发布 |
| 10 | 迁移 0072–0078（expand-only）+ 迁移链单头 | ✅ | ✅（基线头更新 0078） | — | ✅ 未发布 |
| 11 | OpenAPI 契约导出 | ✅ | ✅ `export_openapi --check` PASS | — | — |
| 12 | **admin 静态后台（充值案件页/目录管理/汇率展示）** | ❌ 未实现 | — | — | — |
| 13 | **Flutter 客户端（手机注册页/短信登录/钱包展示/红包抽成展示/客服目录页）** | ❌ 未实现 | — | — | — |
| 14 | 真机联测（Android/iOS 钱包、充值、提现、注册、搜索、红包 UI） | — | — | ❌ 待客户端实现后 | — |
| 15 | 生产发布 / 真实短信供应商开通 / 真实出款 | — | — | — | ❌ 未授权未执行 |

## 二、关键实现位置

- FX：`services/business-api/app/modules/fx/{models,service}.py`、`app/api/fx.py`（`GET /api/v1/fx/rate`）。
- 计价关闭：`app/api/wallet.py`（closed 检查最前，旧客户端 422 `CONVERSIONS_CLOSED`）、`app/core/config.py`（`wallet_user_conversions_closed` 默认 True、与自动兑换互斥校验器）。
- 储备修正：`app/modules/ledger/reserve.py`（`fresh_usd_cny_rate`/`caibi_requirement_usdt`/`reserve_valuation_snapshot`/`refresh_valuation`）、`manual_payout_reserve.py`、`wallet/service.py::_reconcile`（USDT 托管核对只对实际 USDT 义务；无新鲜汇率退化为保守上界，仅门禁用）。
- 红包抽成：`app/modules/redpacket/{models,service}.py`（创建期锁定 beneficiary/rate/规则版本；`_settle_commission` 与 COMPLETED 同事务；`settle_pending_commissions` worker 兜底）；注册表 `app/modules/groups/registry.py`。
- 群冷却：`app/api/groups.py`（`POST /groups/register`、`POST /groups/{room}/transfer-owner`、`GET /groups/{room}/owner`、`POST /admin/groups/{room}/owner-tenure`）。
- 人工提现：`app/modules/wallet/manual_payouts.py`（率结报价/`convert_for_payout`/`adjust_rate`/`_payable` 链上匹配与结算）、`conversions.py`（source≠target 与镜像冲正）。
- 人工充值：`app/modules/recharge/{models,service}.py`、`app/api/recharge.py`（`uq_recharge_evidence` 全局唯一）。
- 手机号：`app/modules/identity/phone.py`（归一化/OTP/`PhoneAuthService`）、`app/api/identity.py`（`/auth/phone/*`、`/contacts/search-phone`）、注册通道扩展。
- 迁移：`0072_fx_rates` → `0073_pricing_v2_reserve` → `0074_red_packet_commission` → `0075_business_groups` → `0076_payout_settlement` → `0077_recharge_requests` → `0078_phone_accounts`（全部 expand-only；0078 对 users 部分唯一手机号索引 + email 改可空 + PG enum ADD VALUE `PENDING_PHONE`）。

## 三、测试证据（真实命令与结果）

统一环境：Python 3.12（`py -3.12`）、Windows、`PYTHONUTF8=1`、`PYTHONPATH=services/business-api;services/business-worker/app;.`（与 verify.ps1 同口径）。

| 范围 | 命令 | 结果 |
| --- | --- | --- |
| FX 服务+API | `py -3.12 -m pytest tests/business_api/fx -q` | **18 passed** |
| 计价 v2 | `py -3.12 -m pytest tests/business_api/pricing -q` | **9 passed** |
| 红包抽成 | `py -3.12 -m pytest tests/business_api/redpacket -q` | **42 passed** |
| 群冷却 | `py -3.12 -m pytest tests/business_api/groups -q` | **35 passed** |
| 提现汇率 | `py -3.12 -m pytest tests/business_api/wallet/test_manual_payout_rate.py tests/business_api/wallet/test_manual_payouts.py -q` | **70 passed** |
| 充值 | `py -3.12 -m pytest tests/business_api/recharge -q` | **7 passed** |
| 手机号 | `py -3.12 -m pytest tests/business_api/identity/test_phone_auth.py -q` | **13 passed** |
| 身份回归 | `tests/business_api/identity` | **280 passed / 10 skipped** |
| 钱包回归 | `tests/business_api/wallet` | **1000 passed / 15 skipped**（修后） |
| 后端全量 | `py -3.12 -m pytest tests/business_api tests/business_worker -q` | 首轮 2286 passed / 6 failed（已全部归因修复）；复跑结果见文末追记 |
| OpenAPI | `py -3.12 scripts/export_openapi.py --check` | **PASS**（已重新导出 `packages/api-contracts/openapi/liuhetong-v1.yaml`） |

测试先行证据：每个批次先落失败用例再实现（fx 表缺失红、`wallet_user_conversions_closed` 属性缺失红、抽成 PENDING 缺失红、调价守卫缺失红、手机 OTP 缺失红等，均已记录于会话执行流）。

## 四、规格符合性自审（领域/质量安全）

1. **余额不变**：关闭与计价切换零余额迁移；`test_balances_and_historical_conversion_unchanged_after_closed_attempt` 断言历史兑换与余额原样。
2. **不重写历史**：红包/兑换/提现旧记录全部原样保留；历史红包迁移回填 `commission_status='NONE'`、`rules_version='rp-fee-v1'`。
3. **资金写四件套**：充值/提现/抽成/群转让全部携带幂等键、稳定 reason code、actor、审计 + Outbox（`recharge.*`、`RED_PACKET_COMMISSION`、`group.owner_transferred`、`wallet.manual_hold_adjust`）。
4. **每资产分别平衡**：`convert_for_payout` 两账本各自平衡；抽成分录 `{PLATFORM_FEE:-c, 群主:+c}` 平衡。
5. **安全门禁未放松**：支付密码/TOTP/双审批/储备门禁保留；`skip_coverage` 仅限内部重分类（`MANUAL_PAYOUT_RATE_ADJUSTED`）与抽成结算；汇率调整豁免严格限于该端点。
6. **日志红线**：OTP 只存哈希；`mask_phone` 脱敏；FX URL/异常脱敏（有测试断言）；手机搜索响应无手机号字段。
7. **E2EE 边界**：短信登录只签发业务会话，未新增任何密钥恢复通道（ADR-0075 决策 3/8）。
8. **已知的诚实取舍（记录在案）**：
   - 无新鲜汇率时储备门禁按 1:1 保守上界计提要求（宁严勿松），ADR-0076 决策 6 有述；报表端不伪造估值（返回 NULL）。
   - 群转让的 Matrix power level 变更由客户端在转让成功后执行（Synapse 无服务端改权接口）；注册表为财务权威，`owner_desync` 只读告警，ADR-0079 决策 3/4 有述。
   - 满 10 人冷却可通过"先踢到 <10 人转让再拉回"规避——用户未批准"曾经满 10 人永久限制"，ADR-0079 决策 6 明确记录该规避空间。

## 五、既有（非本任务）问题记录

- `tests/business_api/wallet/test_admin_deposit_repairs.py::test_expired_repair_preserves_original_facts_and_liability` 与 `tests/business_worker` 单独从根目录收集时因模型导入顺序报 `NoReferencedTableError`——**干净 HEAD 基线复现同样失败**（已用临时 worktree 验证），属既有脆弱性；本任务已在 `receipt_models.py` 显式声明 FK 依赖（`repair_models.ManualDepositCase`）根治该类问题的多数场景。

## 六、发布顺序与回退（未来，需另行授权）

1. 生产部署先跑迁移 0072–0078（expand-only，旧代码兼容）；2. 切换 API/worker 镜像（关闭兑换/自动充值即刻生效）；3. 配置 `FX_API_ID/FX_API_KEY`（服务端 secret）；4. 短信供应商实现 `SmsSender` 协议并配置后方可开 `phone_auth_enabled`；5. admin/客户端随后发版。回退：各开关独立可逆（`wallet_user_conversions_closed`、`wallet_auto_deposit_enabled`、`phone_auth_enabled`）；已执行账本事实不可回滚，纠错只走关联冲正。

## 七、剩余工作（下一会话可执行）

1. admin 静态后台三页（充值案件/目录管理/汇率展示）——服务端 API 契约已冻结（OpenAPI）。
2. Flutter：注册页手机/邮箱二选一 + 短信验证、手机号登录、充值客服目录页、红包抽成/免手续费展示（`fee_exempt`/`commission_status`/`commission_amount` 字段已在 API）、提现 `final_receive`/调价展示。
3. worker 任务专项测试（`RedPacketCommissionSweepTask` 运行接线、`identity.email.otp.requested` 投递分支）。
4. 真机联测（依赖 2）。

## 八、最终门禁追记（2026-09-21）

- 全量复跑（第一轮修复后）：`py -3.12 -m pytest tests/business_api tests/business_worker -q` → 2288 passed / 4 failed；4 个失败全部归因并修复：①`test_migrations.py` 迁移头钉更新至 `0078_phone_accounts`；②计价测试三处**时间炸弹**（fixed NOW 种子在长套件运行中被真实时钟越过 → 储备新鲜度/汇率过期判定翻转）改为真实时钟锚定。
- 修复后定向复跑：`pytest tests/business_api/pricing tests/business_api/test_migrations.py tests/business_api/test_wallet_release_baseline.py -q` → **24 passed**。
- **`pwsh -NoProfile -File scripts/verify.ps1` → 退出码 0（`Verification: PASS`）**，包含：仓库/部署策略、Infra、Getui、Matrix Bot、business_api+business_worker 全量、Flutter boundary（tests/mobile）、UI 契约、Business API import smoke、AST parse、**Alembic 迁移链演练 0001→0078 全链 `Alembic migrations: PASS`**、OpenAPI drift `PASS`、Compose render PASS。verify 内任何门禁失败均会以非零退出，本次退出码 0 即全部门禁通过。
- 说明：verify 输出经 `tail` 截断仅保留末段（迁移演练/OpenAPI/Compose），整体通过性以退出码 0 为准（脚本内 `Assert-LastExitCode` 语义）。
