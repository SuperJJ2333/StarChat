# 任务记录：第二轮五项 UI/交互（红包整页、邀请码、钱包复制位置、充值页、提现按钮）

## 恢复入口

- 目标、用户授权来源及边界：用户 2026-09-17 五项要求（详见
  [验证记录](../../verification/2026-09-17-ui-round2-five-fixes.md) 开头）。第 ① 项交互歧义已确认，用户选择
  **整页红包页**（未领取显示「開」；领取后金额 +「看看大家的手气」进详情；已领取/已过期直接进领取详情）。
  边界：不改红包分配/领取/退款公式与金额计算，不改 E2EE、业务 API 权威性、钱包鉴权与提现审批流程；
  不动 Figma（已退役）；不提高最低支持版本；本次**未构建、未部署**。
- 关联计划/ADR：无新 ADR（均为 UI/交互改动，未触及受保护变更）；遵循
  [移动交付流程](../../runbooks/mobile-delivery-workflow.md) 与 `ui-demo-delivery` 技能。
- 当前状态：**完成**（代码 + 门禁 + 真机 debug 包已覆盖安装并回读核对 + 已推送 `origin/main`）；功能验收待用户。
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
- 下一条具体操作、必要输入、阻断的验收 ID：用户在 Mi 6（已装 **0.3.94-debug/2131**）验收 A1–A5，重点是
  A1「点封面弹居中磨砂弹窗 → 点開 → 响开启音 → 直接进领取详情」；无阻断项。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| A1 | 点红包封面弹**居中磨砂弹窗**（非全屏页）；点「開」领取 → **响开启音 → 直接进入「领取详情」页** | 回退到原 `RedPacketClaimDialog`（`8c97fbf2^` 恢复）；`_claim()` 成功后 `play(redpacketOpen)` → `onClaimed` → `_openClaimRecords()`（关弹窗 + push 详情）；`FinanceMessageEntry` 路由恢复原状 | 红→绿：目标用例改为「领取后播放开启音并直接进入领取详情」（`NotificationFeedback.install` 探针断言 `[SoundType.redpacketOpen]`）；redpacket+finance **87 通过**、扩展集 **165 通过**；`flutter analyze` 无问题 | **debug 2131 已装 Mi 6** | 待用户真机 |
| A2 | 邀请码页不再有「复制邀请链接」 | 删除 `invite-copy-link` 磁贴，保留复制邀请码 | 红：`Found 1 widget with key invite-copy-link`；绿：`invite_code_page_test` 断言两者皆无 | debug 2131 已装 | 待用户真机 |
| A3 | 钱包卡片复制 icon 紧贴钱包地址（不再挂在余额行） | 地址与复制按钮同一 `Row`，余额行只留文本 | 红：复制按钮与地址纵向差 67px（在余额行）；绿：同一行 + 位于地址右侧 + 不在余额行 | debug 2131 已装 | 待用户真机 |
| A4 | 充值页不再有「点钻与 USDT 兑换」卡片 | 充值区只渲染 `card(depositFields())`；删除无入口的组件与其组件级测试 | 红：找到「点钻与 USDT 兑换」；绿：文案/组件均不存在 | debug 2131 已装 | 待用户真机 |
| A5 | 「取消提现申请」红色背景（设计规范 `--color-danger` #FA5151）；无背景色动作按钮有边框 | 新增 `WeChatSecondaryButton(tone: neutral|danger)` + `WeChatColors.dangerFill`；`button()` 无 key 分支、全部提现、取消提现申请分别套用 | 红：三个用例 `Bad state: No element`；绿：断言填充色=#FA5151、白字、边框存在 | debug 2131 已装 | 待用户真机 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| Android debug（Mi 6 真机） | **0.3.94-debug / 2131** | `ad12f92c`（冻结源码工作树，`git status` 干净） | `com.liuhetong.mobile`，固定身份 `75b31c66…ba61fff` | `artifacts/2026-09-17/android-0.3.94-debug-2131/ChatFlow-0.3.94-debug-2131-arm64-rebuilt.apk`，SHA256 `9B4C40D5…D1AFA3`（源包 `CC6F57A8…5611D9`） | 2026-09-17 19:57:26 +08 覆盖安装 **Success**，`firstInstallTime` 2026-09-11 00:42:05 未变（数据保留）；设备回读 `base.apk` SHA256 与证书同候选一致 |
| Android debug（作废） | 0.3.94-debug / 2130 | `8c97fbf2` | 同上 | `artifacts/2026-09-17/android-0.3.94-debug-2130/…-rebuilt.apk`，SHA256 `C420AC9C…F672FE` | 曾安装于 Mi 6，对应**已被用户否决**的整页红包页实现；由 2131 覆盖 |
| Android 正式版 | 未构建（线上仍 0.3.94/2129，本任务前已上线） | — | — | — | — |
| iOS | 未构建 | — | — | — | — |
| 业务 API / worker | 未改动 | — | — | — | — |
| 前端静态 | 仅改 demo 源码（未部署） | `8c97fbf2` | — | `frontend/src/screens/wallet-binding.js` 等 | — |
| GitHub | `origin/main` = `8c97fbf2745b110d9bb119b630cf1ae6cdbf967e` | — | — | `https://github.com/SuperJJ2333/StarChat.git` | 推送 `6bc5fcb8..8c97fbf2`（需 `-c http.sslBackend=openssl`，见验证记录第 6 节） |

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
- 未执行：正式版构建（2129 已在线）、服务端部署、数据库迁移。
- 真机交付（2131，回退后的正确实现）：`-Mode BuildVerify` → `-Mode Install` → `-Mode Pull` 三条命令退出码 0；
  **从干净冻结源码工作树构建**（`git worktree add --detach .worktrees/debug-2131 ad12f92c`，脚本 `-SourceRoot` 切换），
  该工作树 `git status --porcelain` 为 0 字节；语义核对类数 27316/27316、原生与 Flutter 资产 336 项零变化；
  设备回读 `base.apk` SHA256 `9b4c40d5…d1afa3` 与交付候选一致、证书为固定身份；
  `firstInstallTime` 未变。临时工作树已用 `\\?\` 前缀删除并 `git worktree prune`；主工作树他方改动未触碰。
- 推送：`git -c http.sslBackend=openssl push origin main` → `6bc5fcb8..8c97fbf2`（退出码 0）；
  默认 schannel 后端在同一代理下报 `failed to receive handshake`（只读 `ls-remote` 正常），
  未持久化修改 git 配置。

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
