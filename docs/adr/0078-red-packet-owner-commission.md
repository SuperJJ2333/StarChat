# ADR-0078：红包群主抽成 0.1% 与满 10 人群主免手续费

日期：2026-09-21。状态：**已批准（用户 2026-09-21 需求书确认全部规则，含金额示例）**。授权范围：实现与隔离测试；不含生产发布。在 ADR-0073（0.5% 手续费）之上叠加，不改变 0.5% 费率、最低 0.01、舍入与退款政策。

## 背景

- 红包手续费仍为本金 **0.5%**（非 5%），由发送者在本金之外承担（ADR-0073 已实现）。
- 新增：群主抽成 = 红包本金 × **0.1%**，直接进入群主**个人点钻钱包**，不创建群钱包；不要求群达到 10 人。
- 满 10 人免手续费：群实际 **joined** 成员 ≥10 时，**群主本人在该群**发送红包免手续费；免除仅限本群红包，不含转账、提现、其他群。
- 金额示例（用户确认）：普通成员发 100 点钻红包：本金 100、手续费 0.50、实扣 100.50；手续费最终保留时群主得 0.10、平台剩 0.40——**不是**再从用户扣 0.10。满 10 人群主本人发 100：实扣 100、手续费 0、无抽成。

## 决策

1. **创建期快照锁定**（`red_packets` 扩列，迁移 expand-only）：`fee_exempt BOOL`、`fee_exempt_reason TEXT`（`GROUP_OWNER_TEN_PLUS`）、`group_joined_count INT`、`commission_rate NUMERIC(10,6)`、`commission_beneficiary_id TEXT`（= 创建时点**业务群注册表**（ADR-0079）中的群主业务 user_id）、`commission_status TEXT`（`NONE|PENDING|SETTLED|FORFEITED`）、`commission_amount NUMERIC(20,2)`、`rules_version TEXT`（`rp-fee-v2`）。后续群主转让不改变已锁定受益人。
2. **免手续费判定**：仅当 群红包 ∧ 发送者 == 注册表群主 ∧ joined ≥10 → `fee=0`、无抽成（`commission_status=NONE`）。joined 数以服务端权威成员快照（Matrix join 成员，含群主、不含待接受邀请）为准，创建事务内读取。非群主在满 10 人群发红包仍付 0.5% 并产生抽成。
3. **抽成结算时点**：抽成 = `min(最终保留手续费, 本金×0.001)` 两位 HALF_UP；**在红包全部领取（COMPLETED）、手续费最终保留后一次性入账**：`{PLATFORM_FEE: -commission, 群主: +commission}`，reason `RED_PACKET_COMMISSION`、scope `redpacket.commission`、幂等键 `commission:{packet_id}`、skip_coverage，与 COMPLETED 状态翻转同一事务（红包行锁保证并发完成只结算一次）；附加 worker 兜底扫描（PENDING+COMPLETED）幂等补结算。
4. **退款不发抽成**：过期/取消存在未领取份额 → 手续费退回（ADR-0073 口径不变），同事务将 `commission_status: PENDING→FORFEITED`，永不入账——平台不承担已退手续费的返现。
5. **舍入与上限**：抽成两位 HALF_UP，不设最低抽成，舍入为 0 时不强制 0.01；`commission ≤ 最终保留手续费`；平台收入按 `实际手续费 − 抽成` 自然形成，不另立舍入公式制造分录差额。
6. **范围**：私聊红包 `commission_status=NONE`；群专属红包（有 room_id+recipient）按群红包计；群主领取自己的红包（领取本金）不触发再次抽成——抽成是直接账本入账，不经红包/转账通道。
7. **展示**：发起方 detail 返回 `fee`、`commission_status`（待结算显示"待结算"）、`commission_amount`（结算后）；客户端只展示服务端报价与状态，**不得**自行决定免手续费、群主身份、抽成或资金状态；待结算不增加可花余额。
8. **不改动**：红包分配算法、领取并发纪律、过期 worker 触发、支付密码、限额（AppSetting 200）、托管科目命名、E2EE/RBAC/审计/Outbox。

## 迁移与回退

- `0074_red_packet_commission` 扩列，历史红包 `commission_status='NONE'`、`fee_exempt=false` 回填（历史免费/已终结不变）。
- 回退：费率常量与结算开关集中可配（`red_packet_owner_commission_enabled`，默认开启）；关闭后仅新红包不产生抽成；已结算抽成与账本不回滚，纠错走关联冲正。
