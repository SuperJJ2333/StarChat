# 分割线统一收尾（§19 follow-up）验证记录 — 2026-09-19

**范围：** `apps/mobile_flutter`（上一轮遗漏的列表/卡片实心分割线 → 共享 `WeChatGradientDivider`；含转账详情卡片深色缺陷）+ 组件注册表 `packages/ui-contracts/changliao-component-registry.json`（追加 consumers）。
**不属于本次范围（未改动）：** `services/**`、`tests/business_api/**`、`lib/core/outbox/**`、`lib/features/matrix/**`、`lib/app_home.dart`、`lib/features/wallet/**`、`lib/features/caibi/**`、`lib/features/finance/**`、`frontend/**`、`UI_DESIGN.md`（规格本身未改）。
**视觉源：** `frontend/` 下的 HTML demo。**Figma 已退役：本次变更仅更新 HTML demo（本次未新增/修改 demo 文件，逐项核对了对应 demo 页面已在共享 token 上），未触碰任何 Figma 产物。**

**规范依据：** `UI_DESIGN.md` §19（2026-09-19 生效，硬性约束 1/2/4/5 + 例外表）。**上游任务：** commit `d36692e9`（朋友圈/可见范围/通讯录首轮统一）。

**与任务描述的路径差异：** 任务写的 `lib/features/wallet/transfer/chat_transfer_detail_sheet.dart` 在仓库中不存在；实际文件是 `lib/features/transfer/chat_transfer_detail_sheet.dart`（不在 `lib/features/wallet/**` 钱包禁用范围内），因此按「必须转换」处理，未触碰任何钱包目录。

**证据文件：** `docs/verification/artifacts/2026-09-19/divider-followup-{red,green,analyze,focused,full,rescan}.txt`。

---

## 1. 转换清单（before → after）

共享组件：`apps/mobile_flutter/lib/ui/components/wechat_gradient_divider.dart`（`WeChatGradientDivider(height, indent, endIndent)`，色源 `WeChatColors.resolve(context, WeChatColors.divider)`，stops 0/0.18/0.82/1，edge alpha 0 / center alpha 0.5）。行内几何一律沿用既有写法：`Stack` + `Positioned(left/right/bottom: 0)`（`WeChatContactTile` / `WeChatListTile` 既有模式），**行高不变**；缩进由 `indent` 承担。

| # | 文件:旧行 → 新行 | before | after |
|---|---|---|---|
| 1 | `lib/features/profile/profile_page.dart:291-302` → `:292-335`（分割线 `:331`） | `Container(height: 57, padding: …, decoration: BoxDecoration(color: …, border: Border(bottom: BorderSide(width: .5, color: dark ? darkDivider : divider))))` + 直接 `Row` | `Container(height: 57, decoration: BoxDecoration(color: …))` + `Stack(alignment: center)`：「`Padding(horizontal: 16)` + `Row`」+ `Positioned(bottom: 0) → WeChatGradientDivider(key: profile-menu-divider)`。行高仍 57dp、分隔线整行宽（原 border 在 padding 之外，indent 0） |
| 2 | `lib/features/settings/notification/notification_settings_page.dart:322-333` → `:323-336`（上下线 `:330` / `:333`） | 分区卡片 `Container(decoration: BoxDecoration(color: …, border: Border(top: BorderSide(divider), bottom: BorderSide(divider))))` | `Container(key: notification-section-<title>, color: elevatedSurface)` + `Column([WeChatGradientDivider(top), …children, WeChatGradientDivider(bottom)])`；上下各 1dp，分区高度 = 原来（border 内缩 2dp）= 现在（2 条 1dp 线），indent 0 |
| 2b | 同文件 `:395-399` → `:386-401`（分割线 `:397`） | `WeChatSettingsRow` 行尾 `Container(height: 1, margin: EdgeInsets.only(left: 16), color: dark ? darkDivider : divider)` | `const WeChatGradientDivider(key: settings-row-divider, indent: WeChatSpacing.lg)`（16dp 缩进逐字保留） |
| 3 | `lib/features/transfer/chat_transfer_detail_sheet.dart:301-304` → `:299-327`（分割线 `:308`） | 「账单ID」复制行 `Container(decoration: const BoxDecoration(border: Border(top: BorderSide(color: WeChatColors.divider))), padding: …)` | `Column([const WeChatGradientDivider(key: chat-transfer-detail-copy-bill-divider), Padding(原 padding + Row)])` |
| 3b | 同文件 `:322-327` → `:329-348`（分割线 `:332`） | `_row(...)`：`showDivider` 时 `BoxDecoration(border: Border(top: BorderSide(color: WeChatColors.divider)))`，否则 `decoration: null` | `Column([if (showDivider) const WeChatGradientDivider(key: chat-transfer-detail-row-divider), Padding(原 padding + Row)])`；外层明细卡片新增键 `chat-transfer-receipt-detail-card`（`:288`，供回归测试与父级溯源） |
| 4 | `lib/ui/chat/chat_search_page.dart:503-512` → `:504-592`（分割线 `:586`） | `_ResultRow`：`Container(padding:…, decoration: BoxDecoration(color: dark ? darkSurface : lightSurface, border: Border(bottom: BorderSide(width: .5, color: dark ? darkDivider : divider))))` | `Container(decoration: BoxDecoration(color: …))` + `Stack`：「`Padding(原 padding)` + `Row`」+ `Positioned(bottom: 0) → WeChatGradientDivider(key: chat-search-result-row-divider)` |
| 4b | 同文件 `:1204-1212` → `:1224-1268`（分割线 `:1264`） | `ChatCategoryPage._listRow`：`Container(padding:…, decoration: BoxDecoration(border: Border(bottom: BorderSide(width: .5, color: WeChatColors.resolve(context, WeChatColors.divider)))))` | `GestureDetector` 直接挂 `Stack`：「`Padding(原 padding)` + `Row`」+ `Positioned(bottom: 0) → WeChatGradientDivider(key: chat-search-category-row-divider)`（原 `Container` 只剩 child，按 analyzer `avoid_unnecessary_containers` 移除） |
| 4c | 同文件 `:667-681` → `:667-732`（分割线 `:709`） | `MemberPickerPage` 成员行：`Container(padding:…, decoration: BoxDecoration(color: dark ? darkSurface : lightSurface, border: Border(bottom: BorderSide(width: .5, color: dark ? darkDivider : divider))))` | 同 4 的 `Stack` 写法 + `WeChatGradientDivider(key: chat-search-member-row-divider)` |

### 1.2 复扫补漏（同一轮扫描发现的其它非例外实心线，一并转换）

| # | 文件:旧行 → 新行 | before | after |
|---|---|---|---|
| 5 | `lib/ui/notification/conversation_notification_mode_tile.dart:148-153` → `:148-155` | 会话通知三态行尾 `Container(height: 1, margin: EdgeInsets.only(left: 16), color: dark ? darkDivider : divider)` | `const WeChatGradientDivider(key: notification-mode-row-divider, indent: WeChatSpacing.lg)`（容器 16dp padding + 16dp indent = 原位 32dp 左边距） |
| 6 | `lib/ui/chat/chat_forward_picker_page.dart:187-191` → `:188-195` | 转发选择页「最近转发」与「最近聊天」之间 `Container(height: .5, color: resolve(divider), margin: EdgeInsets.only(top: 8))` | `const Padding(EdgeInsets.only(top: 8), child: WeChatGradientDivider(key: forward-picker-section-divider))`（0.5dp → 规范 1dp hairline，8dp 间距保留） |
| 7 | `lib/features/search/global_search_page.dart:451-455` → `:453-457` | `GlobalSearchConversationRecordsPage` 命中行 `separatorBuilder: Container(height: .5, margin: EdgeInsets.only(left: 62), color: WeChatColors.divider)`（**未解析的浅色常量**） | `separatorBuilder: const WeChatGradientDivider(indent: 62)`（62dp 缩进保留，色调按主题解析） |
| 8 | `lib/features/redpacket/red_packet_claim_detail_page.dart:428-432` → `:427-434` | 领取明细行 `Container(height: .5, margin: EdgeInsets.only(left: 62), color: resolve(divider))` | `const WeChatGradientDivider(indent: 62)`（62dp 缩进保留） |

> 为什么 7/8 的分割线不带 `Key`：它们与其它分隔线是同一个 `Column`/sliver 的直接兄弟，常量 Key 会触发 Flutter `Duplicate keys found`（实测 8 会直接抛错）。两者都按「父级 Key（`red-packet-claim-records` / `global-search-conversation-records`）+ `find.byType(WeChatGradientDivider)`」定位，生产代码因此没有合成 Key。首版实现给 8 挂了常量 Key，测试确实抛了 `Duplicate keys found`，已按此改正。

---

## 2. 深色缺陷修复（转账详情卡片画浅灰线）

**缺陷：** `lib/features/transfer/chat_transfer_detail_sheet.dart` 的明细行与「账单ID」行使用 `const BoxDecoration(border: Border(top: BorderSide(color: WeChatColors.divider)))`。`WeChatColors.divider = #D9D9D9` 是**未解析的浅色常量**，`Container`/`BoxDecoration` 不会自行解析 Cupertino 动态色，因此深色模式下在 `darkElevated`（`#232323`）卡片上画出浅灰（217,217,217）实心线。同一缺陷形状也存在于 `global_search_page.dart:454`（复扫时一并修复，见 §1.2 #7）。

**修复：** 两条线都改为共享 `WeChatGradientDivider`，色源在 build 时经 `WeChatColors.resolve(context, WeChatColors.divider)` 解析：浅色 `#D9D9D9`、深色 `darkDivider = #2C2C2C`。§19 硬性约束 2 同时得到满足（"禁止硬编码浅色值"）。

**回归测试（会捕获该行为的断言）：** `test/ui/divider_unification_followup_test.dart`

- `点钻转账详情卡片 › 深色下明细行分隔线不再画浅灰实心线（回归）`：`WeChatTheme.build(Brightness.dark)` 下取渐变色标中段的 RGB，断言 `r=g=b≈44/255`（`darkDivider`）。**旧实现下这里不存在共享组件（0 个候选）→ 红**；修复后为 44 → 绿。同时断言「账单ID」行同理，并遍历 `chat-transfer-receipt-detail-card` 内所有 `Container`，要求 `decoration.border == null`（深色下不得残留任何自拼实心线）。
- `同组 › 明细行与账单ID行改用共享渐隐分割线`（浅色）：断言 3 条行间线 + 1 条账单ID线均为共享组件，色源 `r=g=b≈217/255`，几何 stops 0/0.18/0.82/1、两端 alpha 0、中段 alpha 0.5。
- 深色解析在个人主页菜单行、通知设置行、群成员选择行也各有独立断言（`_expectDarkSource`）。
- `global_search_page.dart` 的同类缺陷：该测试组用 `_expectLightSource` 锁定色源来自共享组件（浅色 `#D9D9D9`），并把「命中行不得含带 border 的 Container」写进断言；深色解析由共享组件保证。

---

## 3. 复扫结果与「保留实心线」例外清单

扫描命令（任务给定，仓库根目录运行；转换前/转换后各跑一次，转换后原始输出见 `docs/verification/artifacts/2026-09-19/divider-followup-rescan.txt`）：

```
git grep -n "Border(bottom\|border-bottom\|height: 1\|ColoredBox\|Divider(" -- apps/mobile_flutter/lib frontend/src
git grep -n "Border(top:\|Border(bottom:" -- apps/mobile_flutter/lib
git grep -n "height: 1,\|height: .5," -- apps/mobile_flutter/lib
git grep -n "ColoredBox($" -- apps/mobile_flutter/lib
Select-String -Path frontend/src/styles/*.css -Pattern "border-(bottom|top)"
```

**Flutter 剩余实心水平线（逐条给出理由）**

| 位置 | 保留理由（§19 例外） |
|---|---|
| `lib/features/moments/moment_composer_page.dart:362-366` | 导航栏边缘线（`CupertinoNavigationBar.border`）→ 例外「导航栏 / TabBar 的上下细线」 |
| `lib/ui/chat/message_action_sheet.dart:115-119` | 多选操作条（58dp 工具条）的上边缘，是控件行自身的边缘而非列表/卡片行分隔线 → 例外「图片编辑器底部控制条」同类（工具条控件行） |
| `lib/features/payment_pin/payment_pin_dialog.dart:297-301` | `Border.all` 支付密码 6 格输入框描边 → 例外「输入类控件与按钮自身的描边」 |
| `lib/ui/components/top_more_menu.dart:128-139`（`TopMoreMenuTokens.divider`，白色 24%） | 深色浮层菜单自带深色 token → 例外「深色浮层菜单的行分隔线」 |
| `lib/ui/components/anchored_action_menu.dart:58-63`（`CupertinoColors.white.withValues(alpha: .24)`） | 同上（HTML `.c-anchored-menu__item`） |
| `lib/features/caibi/caibi_page.dart:104-105` 等 | **已经是**共享组件（`WeChatGradientDivider`，indent 62），非例外 |
| `lib/ui/chat/voice_recording_overlay.dart:242`（`SizedBox(height: 1)`） | 文本多行行距，不是分割线 |
| `lib/ui/chat/group_avatar_mosaic.dart:38`、`lib/ui/components/wechat_contact_index.dart:62`、`conversation_list_tile.dart:49`、`wechat_list_tile.dart:69`、`wechat_contact_tile.dart:42`、`contacts_page.dart:537`、`matrix_home_page.dart:848/1130/1156`、`group_chat_info_page.dart:634/1353`、`direct_chat_info_page.dart:86`、`image_picker_page.dart:1219/1255/1262`、`wechat_video_message.dart:124`、`video_gif_cells.dart:79/99/221`、`message_text_selection.dart:436`、`room_page.dart:4004`、`call_page.dart:375`、`matrix_home_page.dart:1339` | `ColoredBox` / `SizedBox` 是**背景填充或不可见占位**，不是水平分割线（`matrix_home_page.dart:1339` 是 `SizedBox(height: .5)` 无颜色占位符） |

**Flutter 未改动的真实缺陷（属他人持有文件，本次明确不动）**

| 位置 | 说明 |
|---|---|
| `lib/app_home.dart:2940-2951` | 与 #1 完全同形的 57dp 菜单行 + `Border(bottom: BorderSide(width: .5, color: dark ? darkDivider : divider))`。§19 要求改为共享组件。该文件在本次任务中被明确列为 message-outbox 持有文件（且另一 agent 正在改造），**未改动**。建议由 app_home/matrix 拥有者按 #1 的写法替换（`Stack` + `Positioned` + `WeChatGradientDivider`） |
| `lib/features/matrix/chat_red_packet_sheet.dart:601-604`（调用点 `:465`、`:487`） | `_divider() => Container(height: .5, margin: EdgeInsets.only(left: 16), color: WeChatColors.resolve(context, WeChatColors.divider))`，是红包表单的区块分隔线。属 `lib/features/matrix/**`（持有文件），**未改动**；该处已正确解析主题色（无深色缺陷），仅为「第二套实现」的存量 |
| `lib/features/matrix/matrix_home_page.dart:1339` | `SizedBox(height: .5)` 无颜色占位，不构成可见线；文件同时属持有范围 |

**HTML 设计演示剩余实心线（全部命中 §19 例外表，无遗漏、无需改动）**

| 位置 | 例外 |
|---|---|
| `frontend/src/styles/components.css:36` `.c-navigation-bar` | 导航 chrome |
| `frontend/src/styles/components.css:74` `.c-tab-bar` | TabBar chrome |
| `frontend/src/styles/components.css:595` `.c-dialog__actions` | 弹窗操作区（与 `--confirm` 竖线成对） |
| `frontend/src/styles/components.css:983` `.c-anchored-menu__item` | 深色浮层菜单（`--anchored-menu-divider`） |
| `frontend/src/styles/components.css:1063` `.c-image-editor__sheet .c-image-editor__control` | 图片编辑器底部控制条 |
| `frontend/src/styles/admin-*.css`、`gallery.css`、`landing.css`、`download.css` | 管理后台表格/卡片（`--admin-border`） |

**HTML demo 对应面核对（Figma 已退役：本次变更仅更新 HTML demo）**

| Flutter 转换点 | demo 对应面 | demo 现状 | 是否需要改 demo |
|---|---|---|---|
| #1 个人主页菜单行 | `frontend/index.html` → `?module=profile&screen=profile-home-default`（`frontend/src/screens/profile.js:34`，`app-list-tile`） | `.c-list-tile` 已是 `background-image: var(--divider-fade)`（`components.css:212`） | 否（已同 token） |
| #2 通知设置分区/设置行 | `?module=profile&screen=profile-settings-default`（`screens/profile.js:73`，同为 `app-list-tile`） | 同上（demo 无独立「通知与声音」页，行类型相同） | 否 |
| #3 转账详情明细行 | `?module=caibi&screen=caibi-transaction-detail`（`screens/finance.js:169-183`，`.c-ledger-detail`） | demo 用无分隔线的标签/数值网格（`primitives.css:905-924`），**没有**实心行分隔线 | 否（无可镜像的实心线；token 已对齐） |
| #4 聊天记录搜索结果/分类行 | demo 无该页（`register("chat", …)` 只有 room/composer/selection/forward） | — | 否（demo 无对应面）；同 token 的 `.c-conversation-row` 已是渐隐 |
| #5 会话通知三态行 | demo 无「默认/静音/特别关注」页 | — | 否 |
| #6 转发选择页分区线 | `?module=chat&screen=chat-forward-background` | 该页在 demo 中无实心分隔线 | 否 |
| #7 全局搜索命中行 | demo 无该页 | — | 否 |
| #8 红包领取明细 | `?module=redpacket&screen=redpacket-detail-history`（`screens/finance.js:248-251`，`app-transaction-row`） | `.c-transaction-row` 已是 `--divider-fade`（`components.css:817-822`） | 否（已同 token） |

**Token 对照（Flutter ↔ HTML，本次未新增 token）**

| Flutter | HTML (`frontend/src/styles/tokens.css`) |
|---|---|
| `WeChatDividerTokens.hairline = 1.0` | `--size-hairline: 1px` |
| `WeChatDividerTokens.edgeAlpha = 0.0` | `--divider-fade-edge-alpha: 0`（`:138`） |
| `WeChatDividerTokens.centerAlpha = 0.5` | `--divider-fade-alpha: 0.5`（`:137`） |
| `WeChatDividerTokens.coreStart = 0.18` | `--divider-fade-core-start: 18%`（`:139`） |
| `WeChatDividerTokens.coreEnd = 0.82` | `--divider-fade-core-end: 82%`（`:140`） |
| `WeChatColors.divider` / `darkDivider` | `--divider-fade`（浅 `rgb(217 217 217 / …)` `:252-258` / 深 `rgb(44 44 44 / …)` `:263-269`） |

**组件注册表：** `packages/ui-contracts/changliao-component-registry.json` → `components[id=gradient-divider]`（`:421-459`）。variants/states/props/tokens **未变**（组件契约未变），仅按要求**追加 consumers、未重构**：`ProfileExperiencePage menu rows`、`NotificationSettingsPage sections and WeChatSettingsRow`、`ChatTransferDetailSheet receipt rows`、`ChatSearchPage result rows`、`ChatSearchPage category rows`、`MemberPickerPage member rows`、`ConversationNotificationModeTile rows`、`ChatForwardPickerPage section separator`、`GlobalSearchConversationRecordsPage hit rows`、`RedPacketClaimDetailPage claim records`。契约门禁：`UI contract drift: PASS (32 components, 372 screens)`（组件数/页面注册数均未变）。

---

## 4. 红 → 绿证据

测试文件（新增，未删除/未放宽任何既有断言）：`apps/mobile_flutter/test/ui/divider_unification_followup_test.dart`（14 个 testWidgets，覆盖 §1/§1.2 全部 12 个转换点，其中 4 处另带深色解析断言）。

**RED（实现前）** — `flutter test test/ui/divider_unification_followup_test.dart`：

```
00:01 +0 -14: Some tests failed.
Failing tests:
  …/divider_unification_followup_test.dart: 个人主页菜单行 菜单行分隔线改用共享渐隐分割线，行高与整行宽不变
  …/divider_unification_followup_test.dart: 个人主页菜单行 深色下菜单行分隔线按 darkDivider 解析
  …/divider_unification_followup_test.dart: 通知设置 分区卡片上下边线与设置行分隔线改用共享渐隐分割线
  …/divider_unification_followup_test.dart: 通知设置 设置行分隔线保留 16dp 左缩进且行高不因画线改变
  …/divider_unification_followup_test.dart: 通知设置 深色下设置行分隔线按 darkDivider 解析
  …/divider_unification_followup_test.dart: 点钻转账详情卡片 明细行与账单ID行改用共享渐隐分割线
  …/divider_unification_followup_test.dart: 点钻转账详情卡片 深色下明细行分隔线不再画浅灰实心线（回归）
  …/divider_unification_followup_test.dart: 聊天记录搜索 结果行改用共享渐隐分割线
  …/divider_unification_followup_test.dart: 聊天记录搜索 分类行（文件/链接）改用共享渐隐分割线
  …/divider_unification_followup_test.dart: 聊天记录搜索 群成员选择行改用共享渐隐分割线并保留深色解析
  …/divider_unification_followup_test.dart: §19 复扫补漏 会话通知三态行的分隔线改用共享组件并保留 16dp 缩进
  …/divider_unification_followup_test.dart: §19 复扫补漏 转发选择页的分区线改用共享组件
  …/divider_unification_followup_test.dart: §19 复扫补漏 全局搜索会话命中行改用共享组件并保留 62dp 缩进
  …/divider_unification_followup_test.dart: §19 复扫补漏 红包领取明细行改用共享组件并保留 62dp 缩进
```

原始输出：`docs/verification/artifacts/2026-09-19/divider-followup-red.txt`（14 failed / 0 passed）。

**GREEN（实现后）** — 同一命令：`00:00 +14: All tests passed!`
原始输出：`docs/verification/artifacts/2026-09-19/divider-followup-green.txt`。

> 中间态记录：首版实现给红包领取明细的分割线挂了常量 Key，测试抛 `Duplicate keys found`（`Column-[<'red-packet-claim-records'>] has multiple children with key [<'red-packet-claim-record-divider'>]`）。这属于实现缺陷而非测试问题，已按 §1.2 的说明改为父级 Key 定位，生产代码不再有合成 Key。

---

## 5. 门禁输出（真实输出）

```
$ cd apps/mobile_flutter && C:/src/flutter/bin/flutter.bat analyze lib test
Analyzing 2 items...
No issues found! (ran in 6.3s)
```
（原始输出：`docs/verification/artifacts/2026-09-19/divider-followup-analyze.txt`）

```
$ C:/src/flutter/bin/flutter.bat test test/ui test/features/profile test/features/settings test/features/wallet test/ui/chat
00:43 +670: All tests passed!
```
（原始输出：`docs/verification/artifacts/2026-09-19/divider-followup-focused.txt`）

```
$ C:/src/flutter/bin/flutter.bat test --timeout 120s
02:42 +3363: All tests passed!
```
（原始输出：`docs/verification/artifacts/2026-09-19/divider-followup-full.txt`）

```
$ cd D:\pythonProject\outsource\StarChat && python scripts/verify_ui_contract.py
UI contract drift: PASS (32 components, 372 screens)
```

```
$ cd frontend && npm test
ℹ tests 216
ℹ pass 216
ℹ fail 0
ℹ duration_ms 1691.9326
```

> `frontend/**` 本次**未改动**（demo 对应面已在共享 token 上，见 §3），按任务约定 `npm test` 非必需；仍执行以证明无 drift，结果为全绿。`frontend/tests/gradient-divider.test.mjs` 的既有断言（列表/卡片表面必须画 `--divider-fade`、不得再有 `border-bottom/top`、例外线必须仍是实心）包含在 216 条内，未修改。

### 5.1 全量测试

```
$ C:/src/flutter/bin/flutter.bat test --timeout 120s
02:42 +3363: All tests passed!
```

（完整输出：`docs/verification/artifacts/2026-09-19/divider-followup-full.txt`，3363 passed / 0 failed。）

**预先存在的无关失败（非本次引入，未修复）：** `tests/mobile/test_android_ci_workflow.py::test_android_ci_workflow_exists_and_pins_flutter`（Python 侧，属 Android CI workflow；本次未运行 `pytest`，与本次改动无关）。

---

## 6. 改动文件与测试更新说明

**改动（9 个）：**
1. `apps/mobile_flutter/lib/features/profile/profile_page.dart`
2. `apps/mobile_flutter/lib/features/settings/notification/notification_settings_page.dart`
3. `apps/mobile_flutter/lib/features/transfer/chat_transfer_detail_sheet.dart`
4. `apps/mobile_flutter/lib/ui/chat/chat_search_page.dart`
5. `apps/mobile_flutter/lib/ui/notification/conversation_notification_mode_tile.dart`（复扫补漏）
6. `apps/mobile_flutter/lib/ui/chat/chat_forward_picker_page.dart`（复扫补漏）
7. `apps/mobile_flutter/lib/features/search/global_search_page.dart`（复扫补漏 + 同类深色缺陷）
8. `apps/mobile_flutter/lib/features/redpacket/red_packet_claim_detail_page.dart`（复扫补漏）
9. `packages/ui-contracts/changliao-component-registry.json`（仅追加 consumers）

**新增（1 个）：** `apps/mobile_flutter/test/ui/divider_unification_followup_test.dart`

**被更新的既有断言：** 无。四个定向目录（`test/ui`、`test/features/profile`、`test/features/settings`、`test/features/wallet`、`test/ui/chat`）670 条全绿，没有任何既有用例断言过本次改掉的实心线，因此没有「为通过而改断言」的改动。仓库中唯一显式锁定分割线形状的既有用例是 `test/features/moments/moment_divider_unified_test.dart` 与 `test/ui/wechat_gradient_divider_test.dart`，两者针对上一轮已转换的面，本次未触碰也未修改。

**未触碰（受约束）：** `scripts/GETUI_ANDROID_SDK_3.3.15.0/.../.gradle/8.13/fileHashes/fileHashes.lock` 在本次会话开始前就已是 modified 状态（`git status` 首帧即存在），非本次改动，按要求保留原样。

---

## 7. 剩余风险

1. **`lib/app_home.dart:2940-2951` 与 §19 冲突（存量，未修）：** 与 #1 同形的 57dp 菜单行实心底边。属持有文件，建议拥有者用同一写法替换；不修则 §19「禁止第二套实现」在该文件仍有 1 处违例。
2. **`lib/features/matrix/chat_red_packet_sheet.dart:601-604`（存量，未修）：** 表单区块的 0.5dp 实心线（已按主题解析，无深色缺陷）。属持有文件。
3. **0.5dp → 1dp：** 复扫补漏的 #4b/#4c/#6/#7/#8 原为 `width: .5` / `height: .5`，按 §19 几何契约统一为 `hairline = 1.0`。行高由外层决定、内容内缩不变，像素级由 0.5dp 变 1dp（上一轮 `moment_visibility_page` 已是同样的 `.5 → 1.0` 处理）；极端小屏上的视觉差可忽略，但确实是 0.5dp 的差异。
4. **`chat_search_page.dart` 结果行/成员行用 `Stack` + `Positioned` 承载分割线：** 行内容区高度不变（原 `Container.padding` 逐字保留），但若后续在这些行里加入 `Positioned` 兄弟节点需注意 `Stack` 的尺寸语义（非 positioned 子节点决定 `Stack` 尺寸，`Padding` 仍是唯一非 positioned 子节点）。
5. **`notification_settings_page._section` 的上下两条线均改为渐隐线：** 相邻分区之间会出现两条渐隐线相隔 8dp。这是 §19「列表与卡片之间」字面要求的直接结果；若产品认为分区边缘不该渐隐，需要在 `UI_DESIGN.md` §19 例外表新增一条，而不是回退实现。
6. **深色解析覆盖：** 新增断言覆盖了个人主页菜单行、设置行、群成员选择行、转账详情卡片 4 处深色解析；其余转换点（通知分区上下线、转发分区线、全局搜索/红包明细线）依赖同一个共享组件的解析路径（`WeChatColors.resolve`），未逐点写深色用例——共享组件自身的深色行为已有 `test/ui/wechat_gradient_divider_test.dart` 覆盖。
