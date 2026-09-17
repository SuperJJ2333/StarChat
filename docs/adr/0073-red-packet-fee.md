# ADR-0073：红包手续费 0.5%（与转账一致，最低 0.01 点钻）

日期：2026-09-17。状态：**已批准**（用户 2026-09-17 明确批准费率 0.5%、退款口径、迁移与实现；发布次序选定「新客户端先行」）。实现须通过领域与质量/安全审查及测试门禁后方可发布；**API 侧手续费在包含本改动的新客户端发布前不得部署**。

## 背景

- 群聊转账对发送方收取手续费：`TRANSFER_FEE_RATE = Decimal("0.005")`，`transfer_fee(amount) = max(CENT, money(amount * 0.005))`，即 **0.5%，最低 0.01 点钻**（`services/business-api/app/modules/transfer/service.py`）。
- 红包（`services/business-api/app/modules/redpacket/service.py::_create`）目前只记 `{sender: -total, escrow: total}`：**不收取任何手续费**。`tests/business_api/ledger/test_supply_invariant.py` 明确断言"红包相关分录不触碰 PLATFORM_FEE"。
- 用户要求：红包增加与转账相同的手续费（最低 0.01 点钻），并在红包过期、有未领取份额退回时把手续费一并退回。用户原话写的是 0.05%，经核对代码实际为 **0.5%**；用户已确认按"与转账相同"取 **0.5%**。

## 决策

1. **费率**：新增 `red_packet_fee(total) = max(CENT, money(total * RED_PACKET_FEE_RATE))`，`RED_PACKET_FEE_RATE = Decimal("0.005")`，与 `transfer_fee` 逐字同构（同用 `money()` 的两位 HALF_UP 取整与 `CENT = 0.01` 下限）。
2. **创建分录（发送方扣款）**：`{sender_id: -(total + fee), PLATFORM_REDPACKET_ESCROW:{packet_id}: total, "PLATFORM_FEE": fee}` —— 与转账的 `{sender: -(amount+fee), escrow: amount, PLATFORM_FEE: fee}` 同构，保持每笔交易平衡（分录和为零）且手续费在 `PLATFORM_FEE` 可按交易追溯。幂等键、`scope="redpacket.create"`、`reason_code="RED_PACKET_CREATE"`、审计与 Outbox 语义不变。
3. **持久化手续费**：`red_packets` 新增 `fee NUMERIC(20,2)` 列，采用 **expand-migrate-contract**：先加可空列 → 回填历史行为 `0.00`（历史红包确实免费）→ 置 `NOT NULL DEFAULT 0.00`。迁移 `0068_red_packet_fee`，无破坏性变更，不重写既有分录。
4. **退款口径**：红包过期/取消产生的未领取退款，退款金额 = **未领取本金 + 该红包手续费**，退给发送方；分录 `{escrow: -unclaimed, "PLATFORM_FEE": -fee, sender_id: unclaimed + fee}`（合并平衡），与转账到期"本金 + 手续费一并退回发送方"一致。已被领取的部分不退手续费（与转账收款方拿到净额一致）。
5. **余额与文案（客户端）**：红包发送面板必须显示手续费与"实扣合计"，余额校验按 `total + fee` 判断；余额不足的错误必须说明所需合计而不是只说"余额不足"。客户端展示须随本次改动一起发版。
6. **不改动**：红包分配公式（EQUAL/RANDOM/EXCLUSIVE 的份额拆分与取整）、领取流程与幂等、红包状态机与过期 worker 触发条件、`PLATFORM_REDPACKET_ESCROW` 命名与不可变账本语义、E2EE/RBAC/TOTP/审批/幂等/对账/审计检查；不新增 USDT 红包或 USDT P2P。
7. **测试门禁**：手续费边界（`0.01` 下限、`0.5%`、两位 HALF_UP）、分录平衡与 `PLATFORM_FEE` 累计、领取/过期退款（含手续费退回）、幂等重放不重复扣费、余额不足拒绝；`test_supply_invariant.py` 的"红包无手续费"断言改为"红包手续费进入 `PLATFORM_FEE` 且每笔可追溯"。

## 后果

- 与转账口径统一：付费方始终是发起方，平台手续费收入可审计。
- **客户端-服务端兼容风险（必须管理）**：旧客户端（≤0.3.92/2127）按 `total` 校验余额、不展示手续费，因此在"余额刚好够 total"时会被服务端以余额不足拒绝，且旧界面不会解释原因。发布次序必须为新客户端先于/同时于服务端开启；过渡期内红包发送失败的错误信息必须明确指向"含手续费后的合计"。若要求零回归，可先把手续费作为服务端读取投影返回给客户端展示后再开启扣费。
- 财务报表按账户聚合时，红包手续费与转账手续费同处 `PLATFORM_FEE`，可按 `reason_code`（`RED_PACKET_CREATE` vs `CHAT_TRANSFER_CREATE`）区分。
- 储备/负债口径不受影响：手续费从用户余额转入平台手续费科目，用户负债与平台权益同步变化，总额平衡。

## 待批准事项

- 费率 0.5%（最低 0.01 点钻）与退款口径（随未领取部分退回）——**用户已确认**。
- 迁移 `0068_red_packet_fee` 与上述账本公式——**用户已批准**。
- 发布次序——**用户选定「新客户端先行」**：先出新客户端（展示手续费 + 按 total+fee 校余额），再开后端扣费。

## 实施记录

2026-09-17 本地实现完成（**未部署**）：迁移 `0068_red_packet_fee`（加可空列 → 回填 0.00 → NOT NULL DEFAULT 0.00）；
`redpacket/service.py` 新增 `RED_PACKET_FEE_RATE`/`red_packet_fee()`，`_create` 改记
`{sender: -(total+fee), escrow: total, PLATFORM_FEE: fee}`，`_refund` 在存在未领取份额时把未领取本金 + 手续费退回发送方；
`RedPacket.fee` 持久化；创建响应新增 `fee`，`detail` 仅对发起方返回 `fee`；客户端红包面板展示手续费与实扣合计并按
`total+fee` 校验余额。测试先行：新增 `tests/business_api/redpacket/test_red_packet_fee.py`（7 项，实现前因
`red_packet_fee` 缺失收集失败=红），并更新 `test_supply_invariant.py`（原先「红包无手续费」断言改为「红包手续费
同样进入 PLATFORM_FEE 且逐笔可追溯」，同时修正原先把拼写错误的科目名 `PLATFORM_RED_PACKET:` 断言为 0 的空断言）。
后端定向 71 通过；Flutter 钱包套件 75 通过、红包客户端 62 通过、全量 2848 通过 / 0 失败；`flutter analyze` 无问题；
`verify_ui_contract.py` PASS。领域与质量/安全审查见
[验证记录](../verification/2026-09-17-wallet-redpacket-five-items.md)（由独立子代理执行，非自审，双方结论均为
APPROVE-WITH-RESERVATIONS；所提问题已全部处理，见该记录第 6 节）。

## 生产部署（2026-09-17 15:53 +08，用户明确指令「直接部署迁移 0068 与扣费」）

用户指令覆盖了此前"新客户端先行"的次序选择。按 `admin-production-workflow.md` 执行并留证：

- 候选镜像基于**在线镜像**最小覆盖：API `sha256:16522404…` → `starchat-business-api:redpacket-fee-20260917`
  （`sha256:48948fb7…`，覆盖 redpacket service/models、api/redpacket.py 的 `/opt` 与 site-packages 两份 + 0068 迁移文件）；
  Worker `sha256:b5bd6973…` → `starchat-business-worker:redpacket-fee-20260917`（`sha256:f9d03982…`）。
  Worker 的 `service.py` 与仓库 HEAD 存在 +81/−9 的**无关历史差异**，因此按 ADR-0071 r2 教训做**外科合并**
  （+14/−2，仅 `_refund` 手续费退款与 `skip_coverage` 对齐），未整文件覆盖。
- 隔离演练（一次性 PG16）：迁移链 0001→0068 成功；`REHEARSAL_OK`（列 `numeric(20,2) NOT NULL DEFAULT 0.00`、
  创建扣 total+fee 并计入 `PLATFORM_FEE`、过期各退一次、`fee=0.00` 历史红包只退本金、账本全平衡）；
  `downgrade 0067` 后列消失。
- 备份：业务库 `pg_dump -Fc`（`backup/business-db-pre-0068-20260917T075309Z.dump`，sha256 `824cc984…`，0600）+ 前态快照。
- **先迁移后切码**：迁移（expand-only）完成后旧代码仍健康（health 200/401 正常），再切换两个容器。
- 切换后：env 61/65 与挂载/端口不变、部署文件与 payload 逐一相同、真实运行时导入含手续费逻辑、
  live head `0068_red_packet_fee`、52 行历史红包 `fee=0.00`、健康与未授权 401 全部通过、无关容器未变、无 traceback。
- 兼容性（已如实告知并接受）：线上 ≤0.3.93/2127 客户端不展示手续费且按 `total` 校验余额，
  余额处于 `[total, total+fee)` 时会收到带合计说明的 422；历史红包不受影响。
- 完整部署记录与回退步骤：[2026-09-17-redpacket-fee-production-deployment](../verification/2026-09-17-redpacket-fee-production-deployment.md)。
