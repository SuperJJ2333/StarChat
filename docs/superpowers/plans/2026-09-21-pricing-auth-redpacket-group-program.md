# 实施计划：点钻人民币计价 / 人工出入款 / 红包抽成 / 群主冷却 / 手机号注册（2026-09-21）

状态：用户 2026-09-21 需求书批准（设计+实现+隔离测试授权；**不含生产发布、实际出款、生产数据修改**）。
ADR：[0075](../../adr/0075-mainland-phone-registration.md) · [0076](../../adr/0076-caibi-cny-pricing-v2.md) · [0077](../../adr/0077-manual-recharge-withdrawal.md) · [0078](../../adr/0078-red-packet-owner-commission.md) · [0079](../../adr/0079-group-owner-registry-cooldown.md)
任务记录：[2026-09-21-pricing-auth-redpacket-program](../tasks/2026-09-21-pricing-auth-redpacket-program.md)

## 文件所有权（本任务独占；他任务并行时另起工作树）

服务端 `services/business-api/app/**`（modules: fx, recharge, groups/registry, redpacket, wallet/conversions+manual_payouts+safety, ledger/reserve+manual_payout_reserve, identity/phone+models+registration, core/config）、`migrations/versions/0072..0077`、`services/business-worker/app/tasks/**`（红包抽成兜底、充值自动兑换守卫）、OpenAPI 导出。前端 `frontend/src/admin-*.js`（充值案件/目录/汇率）。客户端 `apps/mobile_flutter/lib/features/**`（钱包/红包/注册登录）按批次声明。

## 批次（每批测试先行：失败用例→实现→绿）

1. **FX 汇率服务**：`app/modules/fx/`（models+service）、`0073_fx_rates`、`GET /api/v1/fx/rate`。测试：首取、59min 命中、60min 按需刷新、无人请求零调用、重启保留、并发合并单次上游、money=10 不十倍、失败退避+stale 标注、脱敏。
2. **计价 v2 关闭与储备修正**：`wallet_user_conversions_closed`（默认 True）+ `/wallet/conversions` 422 + 自动兑换守卫 + `_reconcile`/`require_coverage`/`require_manual_payout_coverage` 三处跨单位加法废止 + 储备估值三分类。测试：余额数字不变、旧订单不重写、旧接口拒绝、提现在途按原条款、储备三量断言。
3. **红包抽成与免手续费**：`0074_red_packet_commission`、service 扩展、worker 兜底。测试：0.5%/0.1%、最低手续费、小额舍入 0、满 10 人群主零费零抽成、9 人群主仍付费、抽成≤保留手续费、过期退款 FORFEITED、完成/退款竞争、转让后归属不变、重复结算幂等。
4. **群注册表与转让冷却**：`0075_business_groups`、groups/registry.py、transfer-owner 端点、register 端点、admin 任期迁移。测试：恰满 30 天/差 1 秒、9/10 人、邀请不计入、并发单赢家、Matrix 变更失败回滚、绕过检查。
5. **人工提现汇率**：`0075_payout_settlement`、quote/request/cancel/adjust-rate/reconcile 按率结算与镜像冲正、快照持久。测试：率换算 6 位、调整前后值审计、SETTLED 不可调、旧订单原条款、冲正精确。
6. **人工充值**：`0076_recharge_requests`、recharge 模块+API、目录 API、自动充值关闭守卫。测试：申请单零余额变动、凭证防重、重复回调、客服无权直改余额、审计/Outbox、历史保留。
7. **手机号体系**：`0072_phone_accounts`、identity/phone.py（归一化/OTP/SmsSender）、注册/登录/换绑/搜索端点、限流防枚举。测试：双通道注册兼容、重放、重复号码、旧号→新号、邮箱→新号、隐私搜索、日志脱敏、E2EE 边界断言。
8. **OpenAPI/配置/worker/main 装配**：`export_openapi.py`、Settings 校验器（互斥开关、生产 SMS 必配）、worker 任务。
9. **admin 静态后台**：充值案件页（用户/原始额/参考率/最终率/最终额/记录）、目录管理、汇率展示。
10. **Flutter 客户端**：注册页手机/邮箱二选一 + 短信验证页、手机号登录、钱包兑换入口状态处理（服务端错误文案）、红包抽成/免手续费展示、提现最终应付展示、充值客服目录页。分批 TDD + `flutter analyze` + 定向测试。
11. **门禁与证据**：`pytest tests/business_api`（新增域全绿）、`scripts/verify.ps1`、`docs/verification/2026-09-21-pricing-auth-redpacket-program.md`（含已实现/已测试/待真机/未发布区分、发布顺序与回退）。

## 发布顺序（未来，需另行授权）

后端关兑换+储备修正（expand 迁移先行）→ FX/充值/提现/红包/群冷却 → admin 静态 → Android/iOS 新客户端（含手机注册与展示）→ 生产配置（FX_API_ID/KEY、SMS 供应商）逐项入库。回退：各业务开关独立可逆；账本纠错只走关联冲正。

## 明确不做

USDT P2P/USDT 红包；伪造充值/扣款估值分录；修改历史账本或旧订单金额；固定验证码/伪短信；绕过审批直改余额；把 10 USDT 门槛解释为 10 点钻；"曾经满 10 人永久限制"。
