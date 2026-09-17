# 任务记录：钱包绑定/刷新/告警修复 + 红包手续费（ADR-0073）+ 充值提现美化

## 恢复入口

- 目标、用户授权来源及边界：用户 2026-09-17 五项要求（详见
  [验证记录](../../verification/2026-09-17-wallet-redpacket-five-items.md) 开头）。用户同日确认：
  手续费 **0.5%**（与转账代码一致，非原话的 0.05%）、最低 0.01 点钻、**随未领取部分退回**、
  刷新按钮覆盖钱包四个页面、第 5 项**先 demo 后实现**、**批准 ADR-0073**、发布次序**新客户端先行**。
  边界：不改红包分配公式/领取流程/E2EE/RBAC/TOTP/审批/幂等/对账/审计检查。
- 关联计划/ADR：[计划](../../superpowers/plans/2026-09-17-wallet-redpacket-five-items.md)、
  [ADR-0073](../../adr/0073-red-packet-fee.md)（已批准）、
  [UI demo](../../../frontend/design-demo/wallet-deposit-withdraw-redesign-demo.html)。
- 当前状态：实现与本地门禁完成（**候选 commit `c69e55c2`**，`verify.ps1` 全绿）；**未构建、未真机、未部署**；
  红包手续费按用户要求**必须等新客户端先行**后再发布 API。
- 负责人、工作树、文件所有权、源码 commit：主工作树 `D:\pythonProject\outsource\StarChat`（`main`）。
  拥有：`apps/mobile_flutter/lib/features/wallet/{manual_wallet_page,wallet_page}.dart`、
  `apps/mobile_flutter/lib/app_home.dart`（钱包入口）、
  `apps/mobile_flutter/lib/features/matrix/chat_red_packet_sheet.dart`、
  `services/business-api/app/modules/redpacket/{service,models}.py`、
  `services/business-api/app/api/redpacket.py`、
  `services/business-api/migrations/versions/0068_red_packet_fee.py`、
  对应测试与 `frontend/design-demo/wallet-deposit-withdraw-redesign-demo.html`、文档。
- 最后更新时间（含时区）：2026-09-17 16:0x +08（Asia/Hong_Kong）
- 下一条具体操作、必要输入、阻断的验收 ID：① 用户在真机验收 A1–A3、A5；② 第 4 项需先发新客户端
  （含手续费展示）后再部署 API 迁移 0068 与手续费逻辑——**在此之前不得部署该 API 改动**。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| A1 | 被他人登记的钱包地址提示更换且可删除重填；「更改绑定」按钮 + 30 天限制可见 | 终局失败集合 → `discardBindingDraft()`；地址框只在拿到服务端 `id` 后锁定；统一「重新填写钱包地址」；首页带文字按钮 + `next_rebind_at`；冷却期先解释再禁用 | `wallet_binding_recovery_test`（4 项，实现前红：`enabled==false`/无「更改绑定」文案）；钱包套件 75 通过 | 未构建 | 待用户真机 |
| A2 | 进入钱包不再闪「功能状态暂不可用」；真正失败才提示 | 刷新期间保留已知能力；新增 `capabilitiesUnavailable` 仅「从未可知且失败」为真 | `wallet_page_ux_test`（3 项：加载中不提示/失败提示保持/已知后刷新不回退，实现前红） | 未构建 | 待用户真机 |
| A3 | 刷新按钮在顶部导航栏右侧（钱包四个页面） | `WalletPage` 非嵌入 + 自持导航栏 `trailing`；AppHome 去掉重复 scaffold | `wallet_page_ux_test`（导航栏断言 + AppHome 源码断言，实现前红） | 未构建 | 待用户真机 |
| A4 | 红包手续费 0.5%（最低 0.01）、与转账一致、未领完时手续费随未领取部分退回 | ADR-0073：`red_packet_fee()` + 创建/退款分录 + `RedPacket.fee` 持久化 + 迁移 0068 + 客户端展示与余额校验 | `test_red_packet_fee.py`（7 项，实现前红）、更新 `test_supply_invariant.py`；后端定向 71 通过；客户端 `chat_red_packet_sheet_test` 62 通过 | **未部署**（按用户要求新客户端先行） | 待新客户端 + 真机 |
| A5 | 充值/提现按 demo 美化 | `stepIndicator`/`statusHero`/`rowsCard`；既有 Key 全部保留 | demo 已获用户通过；`wallet_page_ux_test`（2 项结构断言）；钱包套件 75 通过 | 未构建 | 真机观感待验收 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| Android | 未构建（本次未要求） | 工作树 commit | — | — | — |
| 业务 API | **未部署**（迁移 0068 与手续费逻辑仅在仓库） | 工作树 commit | — | — | — |
| 前端静态 | 仅新增 demo 文件，未部署 | — | — | `frontend/design-demo/wallet-deposit-withdraw-redesign-demo.html` | — |

测试记录：

- `flutter test`（全量）：退出码 0，**2848 通过 / 0 失败**（本任务前 2835），
  日志 `docs/verification/artifacts/2026-09-17/flutter-full-wallet-redpacket-five-items.txt`。
- `flutter analyze`：`No issues found!`；`python scripts/verify_ui_contract.py`：`PASS (30 components, 369 screens)`；
  `py -3.12 scripts/export_openapi.py --check`：`OpenAPI contract: PASS`（红包创建路由无 response_model，无 spec 漂移）。
- UI 交付契约：注册表 `packages/ui-contracts/changliao-component-registry.json` 新增
  `walletDepositPayoutRedesign20260917` 修订块（flutter 文件 / HTML demo 路径与 demo id / 状态 / token 映射 /
  行为 / 红包手续费边界 / 验证摘要）与 `tokenParity` 条目 `WeChatColors.warning = --color-warning`；
  两处硬编码 `Color(0xFFFA9D3B)` 改为复用既有 `WeChatColors.warning`，demo 同步用 `--color-warning`（未新造 token）。
- 仓库合并门禁 `pwsh -NoProfile -File scripts/verify.ps1`（commit `c69e55c2`）：**`Verification: PASS`（退出码 0）**——
  Repository/Deployment policy、TemplateTools、Infra render 143、Getui bridge 28、Matrix Bot 9、
  **Business API and Worker 1933 通过 / 58 跳过 / 0 失败**、Flutter boundary 70、UI contract、API import、
  AST parse 219、Alembic 单 head、OpenAPI、Compose render 全部通过；日志
  `docs/verification/artifacts/2026-09-17/verify-wallet-redpacket-five-items.txt`。
- 独立审查（两个独立上下文的子代理，只读）：领域审查 **APPROVE-WITH-RESERVATIONS**（7/7 PASS，提出 D1–D4 与若干缺测试），
  质量安全审查 **APPROVE-WITH-RESERVATIONS**（发现审阅 commit 不含测试修复、PIN 弹窗红包不显示手续费、
  服务端余额不足文案未含手续费、缺隐私断言）。处理见验证记录第 6 节，全部落入 commit `c69e55c2`：
  修复 5 个门禁失败断言、服务端文案含合计、新增 API 余额边界/隐私/审计 Outbox/worker 手续费退款用例、
  客户端手续费实现收敛为 `chatPaymentFee`（BigInt）一处并在 PIN 弹窗对红包同样显示。
- 未执行（发布前置，本次不部署）：生产形态 Postgres 上演练迁移 `upgrade`/`downgrade` 与回填、
  Postgres 同键并发创建用例、客户端不确定结果复用同一幂等键的改造（既有行为）、确认 R3 全额退手续费的商业意图。
- 后端定向：`pytest tests/business_api/{redpacket,ledger,transfer} tests/business_api/test_migrations.py
  tests/business_api/test_wallet_release_baseline.py -q` → **71 通过 / 0 失败**。
- 未执行：未构建 APK/IPA；未部署；未真机。
- 变异/红绿：三类 UI 用例与红包手续费用例均先红后绿（见验证记录第 2 节）。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 侦察（绑定/能力/刷新/收费/UI 位置） | 14:0x | 14:2x | 主动 | — | 源码追踪 | — |
| 第 1–3 项红绿 + 门禁 + commit | 14:2x | 15:0x | 主动 | — | 117 通过；`c9c8386a` | — |
| 第 4 项：ADR → 后端红绿 → 迁移 → 客户端 | 15:0x | 16:0x | 主动（含一次测试算术返工：手续费退回被重复计入预期） | — | 后端 71 + 客户端 62 通过 | — |
| 第 5 项：demo → Flutter 落地 | 15:4x | 16:0x | 主动（含一次 RenderFlex 溢出返工：极端金额需缩放；一次测试路由复用返工） | 与后端并行 | 钱包套件 75 通过 | — |
| 全量门禁 + 文档 | 16:0x | 16:1x | 工具等待 | — | 2848 通过 | — |

总墙钟：约 2 小时（未逐段精确计时，不估成精确值）。

## 交接与回退

- 已确认根因：① 地址登记草稿在终局失败后未清理且输入框以 `bindingOp == null` 为启用条件；
  ② `refresh()` 每次清零能力状态；③ 钱包根页面以 `embedded: true` 渲染，刷新只能落在列表内；
  ④ 转账费率实际为 0.5%（用户原述 0.05% 与代码不一致，已确认按 0.5%）；⑤ 充值/提现为纯样式与信息层级问题。
- 行为变更（需知悉）：红包开始收费（未部署）；钱包地址被拒后不再锁死输入框；钱包首页绑定入口从图标改为文字按钮；
  钱包导航栏由 AppHome 提供改为钱包页自持（无重复标题）；报价/订单明细从 `标签：数值` 单行改为键值分组两列。
- 待办及验收失败项：A1–A3/A5 待真机；A4 待新客户端先行后发布（含迁移 0068）。
- 已发布与仅候选的区别：**本次无任何发布**，全部为本地实现 + 门禁证据。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：不适用（未触碰生产）。发布 A4 时的回退：
  `alembic downgrade 0067_wallet_owner_transfers`（仅删列，不触碰账本）或恢复上一版 API 镜像。
- 运行中 CI/命令/自己创建的隧道（无凭据）：无。
- 下次恢复先检查的事实：`_terminalBindingFailures` 是否仍覆盖服务端终局错误码；`capabilitiesUnavailable`
  是否仍是唯一提示条件；`WalletPage` 是否仍非嵌入且 AppHome 未重新包 scaffold；
  `red_packet_fee` 是否仍与 `transfer_fee` 同构且退款含手续费；迁移 head 是否为 `0068_red_packet_fee`。
