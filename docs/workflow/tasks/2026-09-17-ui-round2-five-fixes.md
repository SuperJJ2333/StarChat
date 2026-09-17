# 任务记录：第二轮五项 UI/交互（红包整页、邀请码、钱包复制位置、充值页、提现按钮）

## 恢复入口

- 目标、用户授权来源及边界：用户 2026-09-17 五项要求（详见
  [验证记录](../../verification/2026-09-17-ui-round2-five-fixes.md) 开头）。第 ① 项交互歧义已确认，用户选择
  **整页红包页**（未领取显示「開」；领取后金额 +「看看大家的手气」进详情；已领取/已过期直接进领取详情）。
  边界：不改红包分配/领取/退款公式与金额计算，不改 E2EE、业务 API 权威性、钱包鉴权与提现审批流程；
  不动 Figma（已退役）；不提高最低支持版本；本次**未构建、未部署**。
- 关联计划/ADR：无新 ADR（均为 UI/交互改动，未触及受保护变更）；遵循
  [移动交付流程](../../runbooks/mobile-delivery-workflow.md) 与 `ui-demo-delivery` 技能。
- 当前状态：**代码与门禁完成，待真机验收**。
- 负责人、工作树、文件所有权、源码 commit：主工作树 `D:\pythonProject\outsource\StarChat`（`main`）。
  拥有：`apps/mobile_flutter/lib/features/redpacket/{red_packet_claim_page,red_packet_claim_dialog(删)}.dart`、
  `apps/mobile_flutter/lib/features/finance/finance_message_entry.dart`、
  `apps/mobile_flutter/lib/features/profile/invite_code_page.dart`、
  `apps/mobile_flutter/lib/features/wallet/{manual_wallet_page,wallet_conversion_card(删)}.dart`、
  `apps/mobile_flutter/lib/ui/components/wechat_secondary_button.dart`、
  `apps/mobile_flutter/lib/ui/foundation/wechat_tokens.dart`、
  `frontend/src/{catalog/contracts.js,components/actions.js,components/register.js,screens/wallet-binding.js,styles/primitives.css}`、
  `packages/ui-contracts/changliao-component-registry.json` 及对应测试。
- 最后更新时间（含时区）：2026-09-17 18:0x +08（Asia/Hong_Kong）
- 下一条具体操作、必要输入、阻断的验收 ID：用户指示是否构建 debug/正式包到 Mi 6 验收 A1–A5；
  无阻断项。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| A1 | 点击红包封面**整页**进入红包页（未领取「開」；领取后金额 +「看看大家的手气」；已领取/已过期直接进领取详情） | 新增 `RedPacketClaimPage`；`FinanceMessageEntry` 按可领取性路由；删除旧居中弹窗 | 红：`red-packet-claim-page` 未找到、`RedPacketClaimDetailPage` 未找到；绿：页面测试 14 例 + entry 测试；全量 2852 通过 | 未构建 | 待用户真机 |
| A2 | 邀请码页不再有「复制邀请链接」 | 删除 `invite-copy-link` 磁贴，保留复制邀请码 | 红：`Found 1 widget with key invite-copy-link`；绿：`invite_code_page_test` 断言两者皆无 | 未构建 | 待用户真机 |
| A3 | 钱包卡片复制 icon 紧贴钱包地址（不再挂在余额行） | 地址与复制按钮同一 `Row`，余额行只留文本 | 红：复制按钮与地址纵向差 67px（在余额行）；绿：同一行 + 位于地址右侧 + 不在余额行 | 未构建 | 待用户真机 |
| A4 | 充值页不再有「点钻与 USDT 兑换」卡片 | 充值区只渲染 `card(depositFields())`；删除无入口的组件与其组件级测试 | 红：找到「点钻与 USDT 兑换」；绿：文案/组件均不存在 | 未构建 | 待用户真机 |
| A5 | 「取消提现申请」红色背景（设计规范 `--color-danger` #FA5151）；无背景色动作按钮有边框 | 新增 `WeChatSecondaryButton(tone: neutral|danger)` + `WeChatColors.dangerFill`；`button()` 无 key 分支、全部提现、取消提现申请分别套用 | 红：三个用例 `Bad state: No element`；绿：断言填充色=#FA5151、白字、边框存在 | 未构建 | 待用户真机 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| Android | **未构建**（本轮仅源码改动） | 见提交 | — | — | — |
| iOS | 未构建 | — | — | — | — |
| 业务 API / worker | 未改动 | — | — | — | — |
| 前端静态 | 仅改 demo 源码（未部署） | 见提交 | — | `frontend/src/screens/wallet-binding.js` 等 | — |

测试记录：

- 红证据：`flutter test`（`finance_message_entry_test` + `invite_code_page_test` + `wallet_actions_ui_test`）
  → 退出码 1、**9 失败**，每个失败原因均为预期缺失行为；日志
  `docs/verification/artifacts/2026-09-17/ui-round2-red.txt`。
- 定向绿：`flutter test test/features/finance test/features/redpacket
  test/features/profile/invite_code_page_test.dart test/features/wallet` → 退出码 0、**172 通过 / 0 失败**；
  日志 `artifacts/2026-09-17/ui-round2-focused-green.txt`。
- 全量：`flutter test`（全量）→ 退出码 0、**2852 通过 / 0 失败**；日志
  `artifacts/2026-09-17/ui-round2-flutter-full2.txt`。首次全量运行出现 1 个与本任务无关的时序用例失败
  （`account_client_selection_test.dart` gallery 准备预算）且因运行中删除 `wallet_conversion_test.dart`
  报一次 `Failed to load`；重跑后两者均消失。
- `flutter analyze` → `No issues found!`（修掉新组件 `minSize` 弃用告警）。
- `py -3.12 scripts/verify_ui_contract.py` → `UI contract drift: PASS (31 components, 369 screens)`。
- `npm test`（frontend）→ 退出码 0、**209 通过 / 0 失败**（修掉 CSS 注释里的硬编码色值）。
- `pwsh -NoProfile -File scripts/verify.ps1` → **`Verification: PASS`（退出码 0）**：Business API and Worker
  1933 通过 / 58 跳过、Flutter boundary 70 通过、UI contract `PASS (31 components, 369 screens)`、
  AST parse 219、Alembic / OpenAPI / Compose render 全通过；日志
  `artifacts/2026-09-17/ui-round2-verify2.txt`。首次运行为 1 failed / 69 passed：
  `tests/mobile/test_ui_component_registry.py` 的硬编码期望 `PASS (30 components, 369 screens)`
  已随新增注册组件更新为 31。
- 未执行：APK/IPA 构建、真机安装、服务端部署、迁移。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 侦察（五项定位 + 交互歧义确认） | 17:0x | 17:2x | 主动（含一次向用户确认红包交互语义） | — | 定位 5 处根因 | — |
| 红用例编写与红证据 | 17:2x | 17:4x | 主动 | — | 9 失败，原因均符合预期 | — |
| 实现 ①–⑤ + demo/registry | 17:4x | 18:0x | 主动（返工 3 次：红包金额/入口并列、测试 handler 路径、按钮组件弃用参数） | — | 定向 172 通过 | — |
| 门禁（analyze/契约/frontend/全量/verify） | 18:0x | 18:3x | 工具等待（全量 2–3 分钟 + verify 约 15 分钟） | 文档并行 | 见第 4 节 | — |

总墙钟：约 1.5 小时（未逐段精确计时，不估成精确值）。返工明细：①页内金额与「看看大家的手气」初版写成 `else if`，
领取后入口消失；②我新增的钱包用例 handler 未按 `/payout-quotes/` 返回报价 fixture、且多点了一次「提现」；
③新组件 `minSize` 弃用 + CSS 注释含 `#fa5151` 违反 source-contract 规则。

## 交接与回退

- 已确认根因：①红包封面入口按「是否已领取」分流，未领取走居中弹窗而非整页；②邀请码页分享区有 5 个磁贴含链接复制；
  ③复制按钮写在「当前点钻余额」`Row` 内；④充值区除 `depositFields()` 外还渲染兑换卡片；⑤`button()` 无 key 分支
  与「全部提现」「取消提现申请」都是无边框/无底色的 `CupertinoButton`。
- 行为变更（需知悉）：点红包封面不再弹居中窗口，而是整页进入；邀请码页少一个分享入口；充值页不再提供兑换入口
  （服务端接口保留）；提现页取消按钮为红底白字，中性动作按钮出现边框。
- 待办及验收失败项：A1–A5 待用户真机；无失败项。
- 已发布与仅候选的区别：**本轮全部为源码 + 门禁，未构建任何包、未部署**。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：不适用（未触碰生产）。如需回退本轮 UI 改动，`git revert` 对应提交即可；
  被删除的旧红包弹窗与兑换卡片可从 git 历史恢复。
- 运行中 CI/命令/自己创建的隧道（无凭据）：无。
- 下次恢复先检查的事实：①`FinanceMessageEntry` 是否仍按 `status == 'OPEN' && viewer_claim == null && !ownPrivatePacket`
  分流到 `RedPacketClaimPage`；②`manual_wallet_page.dart` 的地址行是否仍与 `manual-current-copy` 同 `Row`；
  ③充值区是否只有 `card(depositFields())`；④`button()` 无 key 分支是否仍返回 `WeChatSecondaryButton`；
  ⑤`WeChatColors.dangerFill` 是否仍为 `0xFFFA5151` 且注册表 tokenParity 一致；⑥`redeem`/兑换相关服务端接口未被改动。
