# 2026-09-17 第二轮五项 UI/交互交付（红包整页、邀请码、钱包卡片复制、充值页、提现页按钮）

用户五项要求（原话要点）：①修改领取红包逻辑——点击红包封面后自动跳转进入对应的「红包详情页」，与微信一致；
②个人信息页-邀请码页删除「复制邀请链接」；③钱包卡片的钱包地址复制 icon 移到钱包地址旁边；
「充值页」删除「点钻与 USDT 兑换」卡片；「提现页」的「取消提现申请」按钮改为红色背景（色号参考 UI 设计规范）、
「开启新的提现」「全部提现」等无背景色的按钮要有边框。

第 ① 项的交互歧义已向用户确认，用户选择：**整页红包页**（未领取显示「開」，领取后显示金额 +「看看大家的手气」进详情；
已领取/已过期直接进领取详情）。

## 1. 各改动与红绿证据

### ① 红包封面 → 整页红包页（与微信一致）

- 新增 `lib/features/redpacket/red_packet_claim_page.dart`：`RedPacketClaimPage` 整页（全屏红包渐变 + 导航栏返回键），
  未领取显示「開」，领取后显示金额**并同时**保留「看看大家的手气 >」入口（进入 `RedPacketClaimDetailPage`）。
- `lib/features/finance/finance_message_entry.dart`：可领取（`status == 'OPEN'` 且 `viewer_claim == null` 且非自己发的私聊红包）
  → **push 整页红包页**；已领取 / 已领完 / 已过期 / 已撤回 / 自己发的私聊红包 → 直接 push 领取详情页。
- 删除已无入口的 `red_packet_claim_dialog.dart`（原居中弹窗）与其测试；领取逻辑（controller、领取音、`onClaimed`）
  原样迁移，避免行为漂移。

| 检查 | 结果 |
| --- | --- |
| 红 | `unclaimed red packet opens the full-page claim screen` → `Found 0 widgets with key [<'red-packet-claim-page'>]`；`finished red packet without a claim opens the detail page` → `Found 0 widgets with type "RedPacketClaimDetailPage"`；`claim write invalidates…` 失败 |
| 绿 | `test/features/redpacket/red_packet_claim_page_test.dart`（14 例）+ `test/features/finance/finance_message_entry_test.dart` 全通过 |

实现中一次返工：初版把金额与「看看大家的手气」写成 `else if`，领取后入口消失，与微信不一致；
改为并列 `if` 后 `claim write invalidates…` 通过（该用例同时断言两者可见）。

### ② 邀请码页删除「复制邀请链接」

- `lib/features/profile/invite_code_page.dart`：移除 `invite-copy-link` 磁贴，保留「复制邀请码」；
  文件头注释同步（`shareUrl` 仍是服务端契约字段，仅不再展示入口）。
- 红：`Found 1 widget with key [<'invite-copy-link'>]`（期望 0）；绿：`invite_code_page_test.dart` 通过，
  断言 `invite-copy-link` 与文案「复制邀请链接」均不存在。

### ③ 钱包卡片的复制 icon 移到钱包地址旁

- 现状缺陷：复制按钮（`manual-current-copy`）挂在**「当前点钻余额」行**，不在地址旁。
- `manual_wallet_page.dart`：地址与复制按钮改为同一 `Row`（地址 `Expanded`，按钮紧随其后），余额行只保留余额文本。
- 红：`Expected: a numeric value within <1.0> of <148.0> Actual: <215.0>`（复制按钮与地址纵向相差 67px，即位于余额行）；
  绿：`wallet_actions_ui_test.dart` 断言复制按钮与地址同一行（dy 差 ≤1）、位于地址右侧、且不在余额行。

### ④ 充值页删除「点钻与 USDT 兑换」卡片

- `manual_wallet_page.dart`：充值区只保留 `card(depositFields())`，移除 `WalletConversionCard` 调用与 import。
- 该组件已无任何入口，按「不留死代码」删除 `wallet_conversion_card.dart` 与其**组件级**测试 `wallet_conversion_test.dart`
  （5 例，全部只测该已删除组件）；兑换相关的服务端endpoint与客户端方法保留，`conversionEnabled` 仍作为
  CAIBI 提现能力位参与 `caibiPayoutEnabled` 判定（未改）。
- 红：`Found 1 widget with text "点钻与 USDT 兑换"`（期望 0）；绿：`wallet_actions_ui_test.dart` 断言
  `点钻与 USDT 兑换` / `1 USDT = 1 点钻` / `wallet-conversion-card` 均不存在。

### ⑤ 提现页按钮：红色危险按钮 + 无背景色按钮加边框

- 新增设计 token `WeChatColors.dangerFill = Color(0xFFFA5151)`，取值来自 UI 设计规范
  `frontend/src/styles/tokens.css` 的 `--color-danger: #fa5151`（**不是** Cupertino systemRed；后者仍作文字/图标用的 `danger`）。
- 新增注册组件 `lib/ui/components/wechat_secondary_button.dart`：`WeChatSecondaryButton(label, onPressed, tone)`，
  - `tone: neutral` → 无背景色 + 1px `controlBorder` 边框 + brandPrimary 文案；
  - `tone: danger` → `dangerFill` 填充 + 白字 + 同色边框。
- `manual_wallet_page.dart`：`button()` 的**无 key（原本无背景色）分支**统一改为 `WeChatSecondaryButton`（覆盖
  「重新加载余额」「重新填写金额」「开始新的提现」等）；「全部提现」改为 neutral 边框按钮；
  「取消提现申请」改为 `tone: danger` 红色填充按钮。
- 红：三个用例均 `Bad state: No element`（页面上不存在任何 `WeChatSecondaryButton`）；
  绿：断言「全部提现」「开始新的提现」`color == null` 且 `border != null`；
  「取消提现申请」`color == WeChatColors.dangerFill`、边框同色、文案为白色。

## 2. 顺带修复的一处测试脆弱性（非生产缺陷）

`test/features/wallet/wallet_official_deposit_test.dart` 在 `ensureVisible(...)` 后直接 `tap(...)`（中间不 pump），
点击使用的是上一帧位置；充值页移除兑换卡片后内容变短，该点击开始落空（`copied == null` + `warnIfMissed`）。
已在该用例补 `await tester.pumpAndSettle();`（**仅测试改动**，生产行为无变化），随后通过。

## 3. UI 交付契约（ui-demo-delivery）

- 变更的 Flutter 组件/页面：`RedPacketClaimPage`（新页面）、`InviteCodePage`（移除入口）、
  `ManualWalletPage`（地址复制位置 / 充值区 / 提现区按钮）、`WeChatSecondaryButton`（新组件）。
- HTML demo：`frontend/src/screens/wallet-binding.js`（钱包首页地址旁新增复制按钮；提现页新增红色「取消提现申请」、
  中性按钮改为带边框）、`frontend/src/styles/primitives.css`（`.c-secondary-button{,--neutral,--danger}`、
  `.c-wallet-demo__button--danger`、地址行样式）。
- 注册表：`packages/ui-contracts/changliao-component-registry.json` 新增组件 `secondary-button`
  （flutter `WeChatSecondaryButton` / html `app-secondary-button` / variants `tone: neutral|danger` /
  tokens `controlBorder,brandPrimary,dangerFill`）与 tokenParity 条目
  `--color-danger: #fa5151` ↔ `static const dangerFill = Color(0xFFFA5151);`。
- 契约与 demo 实现：`frontend/src/catalog/contracts.js` 新增 `app-secondary-button` 契约（rootClass `c-secondary-button`）、
  `frontend/src/components/actions.js` 新增 `AppSecondaryButton`、`frontend/src/components/register.js` 注册该标签。
- **Figma 已退役：本次变更仅更新 HTML demo（`frontend/src/screens/wallet-binding.js`、`frontend/src/styles/primitives.css`）。**
- 目录页可见位置：`frontend/index.html` → 钱包分类下的「钱包 / 已绑定」（地址旁复制按钮）与「提现 / 默认」等状态
  （红色取消按钮 / 带边框中性按钮）。

## 4. 门禁结果

| 门禁 | 命令 | 结果 |
| --- | --- | --- |
| 冻结点红证据 | `flutter test`（4 个目标文件） | 退出码 1，**9 个失败**，每个均为预期缺失行为；日志 `artifacts/2026-09-17/ui-round2-red.txt` |
| 定向绿 | `flutter test test/features/finance test/features/redpacket test/features/profile/invite_code_page_test.dart test/features/wallet` | 退出码 0，**172 通过 / 0 失败**；日志 `artifacts/2026-09-17/ui-round2-focused-green.txt` |
| 静态分析 | `flutter analyze` | `No issues found!`（退出码 0）；期间修掉新组件里 `minSize` 弃用告警（改 `minimumSize`） |
| 全量 Flutter | `flutter test`（全量） | 退出码 0，**2852 通过 / 0 失败**；日志 `artifacts/2026-09-17/ui-round2-flutter-full2.txt` |
| UI 契约 | `py -3.12 scripts/verify_ui_contract.py` | `UI contract drift: PASS (31 components, 369 screens)`（组件 30→31） |
| HTML demo 测试 | `npm test`（frontend） | 退出码 0，**209 通过 / 0 失败**（期间修掉 CSS 注释中的硬编码色值，违反 source-contract 规则） |
| 仓库门禁 | `pwsh -NoProfile -File scripts/verify.ps1` | **`Verification: PASS`（退出码 0）**：Repository/Deployment policy、Infra render 143、Getui 28、Matrix Bot 9、**Business API and Worker 1933 通过 / 58 跳过**、**Flutter boundary 70 通过**、UI contract `PASS (31 components, 369 screens)`、AST parse 219、Alembic / OpenAPI / Compose render 全通过；日志 `artifacts/2026-09-17/ui-round2-verify2.txt` |

首次 `verify.ps1` 为 **`1 failed, 69 passed`**：`tests/mobile/test_ui_component_registry.py` 把契约输出字符串硬编码为
`PASS (30 components, 369 screens)`。新增注册组件后组件数为 31，该期望值属本次变更的一部分，已同步更新为 31
（仅此一处「活」断言；历史验证记录与历史 revision 块中的「30 components」是当时的事实陈述，保持原样不追改）。

一次性波动（非本次改动）：全量首次运行中 `test/features/matrix/account_client_selection_test.dart`
的「owner atomically accepts nine deferred gallery videos within one preparation budget」失败一次，
重跑即通过（该用例带准备预算的时序敏感断言，本任务未触碰 matrix/gallery 代码）；
另首次全量运行因我在测试进行中删除了 `wallet_conversion_test.dart` 而报该文件 `Failed to load`，
重跑后消失。

## 5. 真机交付（debug 0.3.94-debug/2130，Mi 6 覆盖安装，数据保留）

按 [android-apk-rebuild.md](../../runbooks/android-apk-rebuild.md) 固定流程（**debug** 变体）：
Flutter ARM64 debug 源包 → Apktool 2.12.1 解码/重建 → zipalign 36.0.0 `-P 16 -f 4` →
固定身份 `75b31c66…ba61fff` 签名 → 语义/对齐/清单/签名核对。脚本
`artifacts/2026-09-17/android-0.3.94-debug-2130/build-debug-2130.ps1`（`-Mode BuildVerify|Install|Pull`，三条命令退出码均 0）。

版本号取 **2130**：沿用上一轮「正式版 +1」的约定（正式版 0.3.94/2129，此前 debug 为 0.3.93-debug/2128），
既高于设备已装的 2128，也不与正式版 2129 同号。

| 项 | 值 |
| --- | --- |
| 源码 commit | `8c97fbf2745b110d9bb119b630cf1ae6cdbf967e` |
| 源包 SHA256 | `C8E158A4685BB9F410E5D80ACE5FF8CCD8772C3065200F4C3982EB5EF5ED5D09`（150,824,845 字节） |
| 重建交付包 SHA256 | `C420AC9C63FC4BFDCF8FE9A22AD47FF89D28FF0D7241116F76342E72C8F672FE`（144,625,963 字节） |
| 重建语义核对 | 源/最终类数 27316/27316、`changed_smali_classes=[]`、原生与 Flutter 资产 336 项零变化、`manifest_semantics_identical=true`、`manifest-semantics.diff` **0 字节** |
| 清单身份 | `com.liuhetong.mobile` versionCode **2130** / versionName **0.3.94-debug** / `application-debuggable` / native-code `arm64-v8a` |
| zipalign / 签名 | `-c -P 16 4` 通过；apksigner v2+v3，证书 `75b31c66…ba61fff` |
| 安装 | `adb -s cbd0156b install -r` → **Success**；versionCode 2130、`flags=[DEBUGGABLE …]` |
| **数据保留** | `firstInstallTime=2026-09-11 00:42:05` **未变**（未卸载、未清数据）；`lastUpdateTime=2026-09-17 19:34:46` |
| 设备回读 | 拉回 `/data/app/.../base.apk`：SHA256 `c420ac9c…f672fe` **与交付候选完全一致**，证书 `75b31c66…ba61fff` 一致 |

## 6. GitHub 推送

- 首次 `git push origin main` **失败**：`schannel: failed to receive handshake, SSL/TLS connection failed`
  （本机 git 配置 `http.sslBackend=schannel` 且 `http(s).proxy=http://127.0.0.1:7897`；
  同一时刻只读的 `git ls-remote` 正常，说明代理链路本身可用，问题出在 schannel 的推送握手）。
- 用一次性覆盖（**未改持久配置**）成功：
  `git -c http.sslBackend=openssl push origin main` → **`6bc5fcb8..8c97fbf2 main -> main`**（退出码 0）。
- 推送后 `git rev-list --left-right --count origin/main...main` = `0  0`，
  `origin/main == main == 8c97fbf2745b110d9bb119b630cf1ae6cdbf967e`。
- 后续如再次遇到同一 schannel 报错，可重复该覆盖命令，或由用户决定是否把 `http.sslBackend=openssl`
  写入仓库/全局配置（本任务未擅自持久化）。

## 7. 未执行 / 待用户确认

- **未部署任何服务端变更**（本轮无服务端改动）；未改更新弹窗设置；未构建正式版包（2129 已在线）。
- 真机功能验收（A1–A5）由用户在 Mi 6 上执行。
- 删除「复制邀请链接」与「点钻与 USDT 兑换」卡片后，相关服务端契约字段/接口保持不变（仅去 UI 入口）。
