# 充值页（5 项）+ 提现页（8 项）UI/交互修正 + 通知栏（1 项）验证记录（2026-09-18）

- 日期：2026-09-18
- 范围：`apps/mobile_flutter/lib/features/wallet/**`、`lib/features/caibi/caibi_page.dart`、其测试、`UI_DESIGN.md` §20、本记录。
- 不在范围（并发边界，未修改）：`lib/features/finance/**`（钱包进入态 Store 的作者）、`lib/app_home.dart`、`lib/features/matrix/**`、`frontend/**`、服务端。
- 未提交 commit（由父 agent 统一提交）。
- 设计源：`frontend/design-demo/wallet-deposit-withdraw-redesign-demo.html`（充值/提现页评审稿）+ `docs/verification/2026-09-18-wallet-entry-flash.md` §7（进入态 patch P1–P8、§7.2 点钻页）。

## 0. 结论摘要

| 需求 | 结果 | 位置 |
|---|---|---|
| 充值 1 删除「查看本次充值」 | 完成（仅保留「结果未确认」草稿的同键重试） | `manual_wallet_page.dart` depositFields |
| 充值 2 地址压缩 + 左对齐（复制仍完整） | 完成（首 8 + … + 末 6；行内边距与 `detail()` 一致） | `wallet_display.dart:compactWalletAddress`、`manual_wallet_page.dart:addressRow/codeRow` |
| 充值 3 二维码「保存到本地」真实可用 | 完成（权限 → 真实 PNG → 相册；loading/成功/失败/无权限都可读） | `wallet_qr_exporter.dart`、depositFields |
| 充值 4 收款地址上方明显分割线 | 完成（共享 `WeChatGradientDivider`，`manual-deposit-address-divider`） | depositFields |
| 提现 5 step 保留 + 进度动效（减少动态效果） | 完成（`AnimatedContainer`，`disableAnimations` → `Duration.zero`） | `stepIndicator`、`payoutStep` |
| 提现 6 输入框与「全部提现」间距 ≥12dp | 完成（`WeChatSpacing.md`） | payoutFields |
| 提现 7 余额放大分层（深浅色） | 完成（34sp w700 + 次级色副信息 + `FittedBox` 防溢出） | `pointsBalanceHero` |
| 提现 8 删除「查看本次提现」 | 完成 | payoutFields |
| 提现 9 地址压缩 + 左对齐 + 完整复制 | 完成（与充值共用 `addressRow`） | payoutFields |
| 提现 10 删除「查看详情」，直接展示订单码 + 复制 | 完成（`codeRow`，字号 `caption`，复制完整值） | payoutFields / `codeRow` |
| 提现 11 确认前金额可改、与「全部提现」联动、提交以最终输入为准 | 完成（改动即作废旧报价：旧报价不再展示/不可提交；「下一步」按最终金额重新报价） | `payoutQuoteMatchesInput`、`normalizedPayoutInput`、`createQuote` |
| 提现 12 确认有效期 24 小时 | **部分**：前端已只展示/校验服务端权威 `expires_at`（含 23h59m 档位回归），但 **24 小时本身是服务端策略**（现默认 300s、上限 3600s），需服务端 patch，见 §6 | payoutFields、服务端 patch |
| 提现 13 确认后只以「处理中」呈现一次 | 完成（报价卡与确认区在 `payout != null` 时不再渲染） | payoutFields |
| 通知栏 14 提醒统一到导航栏下方 + 「不再通知」持久化 | 完成（固定通知栏、按申请身份持久化忽略、新申请重新出现） | `wallet_notice_store.dart`、`noticeBars()/noticeBar()` |
| 追加：进入态缓存优先（W1 patch P1–P8 + §7.2） | 完成（钱包页 + 点钻页接入 `WalletEntryStore`；`run(cacheFirst:)`；见 §1「追加」） | `manual_wallet_page.dart`、`caibi_page.dart` |

## 1. 逐条改动（需求 → file:line）

> 行号以本次最终文件为准（`manual_wallet_page.dart` 约 2000 行、`caibi_page.dart` 约 400 行）。

### 充值页

1. **删除「查看本次充值」**：`lib/features/wallet/manual_wallet_page.dart:1665-1670`
   - 申请生成后由 `refresh()` 自动恢复展示（服务端权威），按钮只在两种「需要用户动作」的情况出现：`depositOp == null`（下一步）或 `depositOp['id'] == null`（结果未确认 → 「重试本次充值」，复用同一幂等键）。不存在任何「查看」语义的入口。
2. **地址压缩 + 左对齐**：`lib/features/wallet/wallet_display.dart:12-25`（`compactWalletAddress`：首 8 + `…` + 末 6，短值原样返回）、`manual_wallet_page.dart:930-953`（`addressRow` 内部 `Padding(horizontal: WeChatSpacing.lg)` + `TextAlign.left` + `Key('<key>-display')`）、`956-984`（`codeRow` 同款）。
   - 复制 icon 仍复制 **完整** 值（`copyIcon(value, key)`，`copyIcon` 定义紧随其后）。
3. **二维码「保存到本地」图形 icon**：`manual_wallet_page.dart:1700-1716`（`iconActionButton(key: 'manual-deposit-qr-save', icon: square_arrow_down, label: '保存到本地', loading: savingQr)`）、`saveDepositQr()`（`manual_wallet_page.dart:851-881`：`widget.qrExporter.saveQrCode` → 成功 `收款二维码已保存到相册`／失败 `walletQrExportErrorMessage`）、生产导出器 `lib/features/wallet/wallet_qr_exporter.dart:30-94`（`ensureGallerySaveAccess()` → 白底静区 PNG（`renderQrPng:57`） → `PhotoManager.editor.saveImage`；空 id / 权限被拒都抛可读异常）、widget 注入点 `ManualWalletPage.qrExporter`（并透传到 `openSection` 推入的子页面，`manual_wallet_page.dart:448`）。
4. **收款地址上方的明显分割线**：`manual_wallet_page.dart:1695-1699`，使用共享组件 `WeChatGradientDivider(key: 'manual-deposit-address-divider')`；同页 `rowsCard` 单元格分隔线也统一为共享组件（`manual_wallet_page.dart:1196`，原 `Container(height: .5)` 属 §19 禁止的第二套实现）。

### 提现页

5. **鱼骨导航保留 + 进度动效**：`stepIndicator(..., keyPrefix: 'manual-payout-step')`（`manual_wallet_page.dart:1063-1117`：`AnimatedContainer(duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : WeChatMotion.actionPressDuration)`；已完成 = 品牌色 + `manual-*-step-check-N` 勾号，当前 = 品牌色，未完成 = 表面色 + 次级文字）、`payoutStep`（`1741-1746`：报价 → 1，订单/已提交 → 2）、步骤条不再随 `quote != null` 消失（`1806`）。
6. **间距 ≥12dp**：`manual_wallet_page.dart:1827-1829`（`SizedBox(width: WeChatSpacing.md)` 插在 `Expanded(field)` 与「全部提现」之间）。
7. **余额放大分层**：`pointsBalanceHero()`（`manual_wallet_page.dart:1760-1807`）——标签 `subhead` + `resolve(textSecondary)`；数字 `WeChatTypography.brand` w700 + `resolveTextPrimary`；单位 `callout` + secondary；说明 `caption` + `resolve(textTertiary)`；`FittedBox(scaleDown)` 防长金额溢出；key `manual-payout-points-balance` / `manual-payout-points-value` 保持。
8. **删除「查看本次提现」**：`manual_wallet_page.dart:1862-1874`（按钮只在无报价、报价未确认、或金额已改时出现，文案为「下一步」/「重试本次提现报价」/「按新金额重新报价」）。
9. **收款地址压缩 + 左对齐 + 完整复制**：共用 `addressRow`（见充值 2），`quote.targetAddress` 以压缩值展示，`manual-target-copy` 复制完整地址。
10. **删除「查看详情」**：`manual_wallet_page.dart:1894`（`codeRow('订单校验码', quote.digest, 'manual-quote-digest')`，字号 `WeChatTypography.caption` + 复制完整 64 位校验码；`manual-quote-digest-display` 是展示文本）、处理中订单号同样用 `codeRow('订单', payout.id, 'manual-payout-id')`（`1948`）；`showOrderDetails` 状态已删除。
11. **确认前金额可改 + 联动 + 以最终输入为准**：
    - 输入框 `enabled: payoutOp == null`（`manual_wallet_page.dart:1823-1825`）：报价生成后仍可编辑，只有已提交订单后才锁定。
    - 「全部提现」在 `payoutOp == null` 时可用（`1831-1845`），`fillAll()` 去掉 `quoteOp != null` 的禁用（`419-431`）→ 与输入框联动一致。
    - 一致性判定 `payoutQuoteMatchesInput`（`341-345`）+ `normalizedPayoutInput`（`331-339`）：金额与报价绑定的输入不一致时，报价卡与「确认提现」**都不渲染**（不可能用旧报价提交），并显示 `manual-payout-amount-changed` 提示（`1876-1886`）。
    - `createQuote()`（`635-684`）在金额被改后先丢弃旧报价记录再按最终金额重新报价（新幂等键；旧报价只是价格预览，无资金影响）。
12. **确认有效期**：报价卡只渲染服务端 `quote.expiresAt`（`detail('确认有效期', shortDate(quote!.expiresAt))`，`1889-1891`），本地过期判断用同一个时间点（确认按钮 `widget.clock().isBefore(quote!.expiresAt)`，`1916-1923`），前端没有任何硬编码时长。**24 小时需服务端策略改动**（§6）。
13. **确认后只呈现「处理中」一次**：报价卡 `if (quote != null && payout == null && payoutQuoteMatchesInput)`（`1871`）+ 确认区 `payoutOp?['id'] == null && payout == null && ...`（`1898-1912`）→ 订单生成后同一笔只渲染 `manual-payout-status-hero` + 订单明细一次。

### 通知栏

14. **提醒统一到顶部导航栏下方 + 「不再通知」持久化**：
    - 身份判定 `lib/features/wallet/wallet_notice_store.dart:9-31`（`depositNoticeIdentity` / `payoutNoticeIdentity`：报价与订单通过 `quote_id` 串成同一身份，新报价/新订单才有新身份）。
    - 持久化忽略 `WalletNoticeStore`（`wallet_notice_store.dart:38-83`，键 `wallet.notice.v1:<钱包作用域>:<kind>`，值为被忽略的申请身份）。
    - 通知栏 UI `manual_wallet_page.dart:1391-1461`（`noticeBars()/noticeBar()`：固定位置、整条可点直达、最右 `bell_slash` + `Semantics('不再通知')`、保存失败可见、进行中 loading）、`dismissNotice()`（`821-848`）。
    - 固定位置：`build()` 中 `Column([...noticeBars(), Expanded(ListView)])`（`1497-1543`），在 `SafeArea` 内、`wallet-page-list` 之外；原卡片下方的两个按钮已删除（`overview()` 末尾仅留注释）。

### 追加：进入态缓存优先（父 agent 要求并入）

- 网关 `_WalletEntryGateway`（`manual_wallet_page.dart:1988-2009`：能力配置 + 余额合并为一份快照，作用域变化即失败，不返回别的账号数据）。
- `_bootstrap()`（`173-263`）：本地读取 → `WalletEntryStores.of(scope, gateway)`（复用共享缓存）→ `entry.view.addListener(_applyEntryState)` → `enter()`（有缓存立即返回）→ `run(refresh(refreshEntry: false), cacheFirst: shared.state.hasData)`。
- `_applyEntryState()`（`219-262`）：只在有快照时更新能力/余额，**从不清空**；只有 `fatalError` 才提示。
- `refresh({refreshEntry})`（`260-345`）：能力配置改走 `entry.refresh()`，删掉尾部重复的余额请求；`readPointsBalance()`（`403-422`）改为缓存优先（成功才更新、失败保留旧值）；`run(..., cacheFirst:)`（`452-495`）：有缓存的后台刷新失败静默保留（不弹错、不整页 busy）。
- `dispose()` 只 `removeListener`（`806-817`）。
- 点钻页 `lib/features/caibi/caibi_page.dart`：三路请求合并为一个快照（`_CaibiEntryGateway`，`caibi_page.dart:428-476`），余额/流水/本月汇总改为读 `entry.state`（`_balanceHero:145` / `_recentSection:211` / `_monthlyHeader:293`），只有 `fatalError` 显示「暂不可用/流水加载失败 + 重试」；作用域用 `<钱包作用域>#caibi` 与钱包页隔离（`caibi_page.dart:68`）；行分隔线改用共享 `WeChatGradientDivider`（`caibi_page.dart:104-105`）。

## 2. 红 → 绿证据（真实输出）

**红 1（需求 1，可复现）**：把充值页按钮条件临时改回「有申请就显示查看」并重新运行
`flutter test test/features/wallet/wallet_recharge_ui_test.dart --plain-name "需求1：已生成的充值申请不再有「查看本次充值」按钮"`
完整输出：`docs/verification/artifacts/2026-09-19/red-recharge-no-view-button.txt`

```
00:00 +0: 需求1：已生成的充值申请不再有「查看本次充值」按钮
Expected: no matching candidates
  Actual: _TextWidgetFinder:<Found 1 widget with text "查看本次充值": [
   Which: means one was found but none were expected
00:00 +0 -1: Some tests failed.
```

**红 2（需求 2，可复现）**：地址展示临时改回完整原文
`flutter test ... --plain-name "需求2：地址压缩展示、文字靠左对齐、复制仍是完整地址"`
完整输出：`docs/verification/artifacts/2026-09-19/red-recharge-address-compact.txt`

```
Expected: exactly one matching candidate
  Actual: _TextWidgetFinder:<Found 0 widgets with text "T2222222…222222": []>
00:00 +0 -1: Some tests failed.
```

**红 3（需求 3 保存到本地，实现过程中真实输出）**：注入的假导出器从未被调用
（子页面 `openSection` 没有把 `qrExporter` 透传下去），点击保存后页面停在 loading：

```
00:02 +0 -1: 需求3：二维码保存到相册成功，保存的是完整收款地址
  The following assertion was thrown running a test: pumpAndSettle timed out
  #1 TestAsyncUtils.guard.<asynchronous suspension>
  #2 tap (manual_wallet_flow_test.dart:52:3)
（实现前：button onPressed null? true / save-button indicator: 1 / calls: 0）
```

**红 4（需求 5 步骤条，实现过程中真实输出）**：`CrossAxisAlignment.baseline` 缺 `textBaseline`
导致提现页构建失败、步骤文案全丢：

```
The following assertion was thrown building ManualWalletPage(dirty, ...):
textBaseline is required if you specify the crossAxisAlignment with CrossAxisAlignment.baseline
  Actual: _TextWidgetFinder:<Found 0 widgets with text "填写金额": []>
```

**红 5（需求 14 通知栏，实现过程中真实输出）**：通知栏点击用 `run(open)` 包裹后
`openSection` 的 busy 守卫拒绝跳转 → 目标按钮永不出现：

```
00:00 +0 -1: WALLET_PAYOUT_QUOTE_EXPIRED clears a recovered payout ...
  The following StateError was thrown running a test: Bad state: No element
  #2 WidgetController.dragUntilVisible (controller.dart:2482)
```

**红 6（追加：缓存优先，session 真实输出）**：接入前 `wallet_page_ux_test`
「能力真正加载失败时才提示，且提示保持可见」在共享 Store 泄漏（未清注册表）时
`attempts == 0`；接入后需要每个用例 `WalletEntryStores.disposeAll()`：

```
Expected: a value greater than <0>
  Actual: <0>
```

**绿（最终）**

```
$ C:/src/flutter/bin/flutter.bat test test/features/wallet test/features/caibi test/features/finance test/ui
00:31 +675: All tests passed!
```

新增用例（本次新增 4 个文件 + 1 个点钻页文件，共 5 个文件）：

| 文件 | 覆盖 |
|---|---|
| `test/features/wallet/wallet_recharge_ui_test.dart` | 充值 1/2/3/4 + 未确认草稿同键重试 + 保存 loading/失败/无权限 + 窄屏不溢出（9 条） |
| `test/features/wallet/wallet_withdraw_ui_test.dart` | 提现 5/6/7/8/9/10/11/12/13 + 减少动态效果 + 深色 + 窄屏（13 条） |
| `test/features/wallet/wallet_notice_bar_test.dart` | 通知栏 14：身份语义、位置（导航栏下方、不在列表内）、点击直达、持久化忽略、重启后仍隐藏、新申请重新出现、提现提醒、深色（5 条） |
| `test/features/wallet/wallet_entry_cache_test.dart` | 进入态：有缓存先渲染 + 刷新失败不弹错（`fatalError=false`）；无缓存首次失败必须可见（`fatalError=true`）（2 条） |
| `test/features/wallet/wallet_qr_export_test.dart` | 生产导出器真实路径（Android 9- 权限请求 → 真实 PNG 魔数/字节 → `saveImage` 落相册；Android 10+ 不请求旧权限；权限被拒不写相册）+ 压缩/错误文案纯函数（4 条） |
| `test/features/caibi/caibi_page_test.dart` | 点钻页：缓存优先、失败保留、无缓存失败 + 重试恢复、流水单独失败不隐藏余额、无网关空态（4 条） |

## 3. 门禁结果（真实输出）

| 命令 | 结果 |
|---|---|
| `cd apps/mobile_flutter && C:/src/flutter/bin/flutter.bat analyze lib test` | **`No issues found! (ran in 3.0s)`，exit 0**（完整输出 `docs/verification/artifacts/2026-09-19/wallet-recharge-withdraw-analyze.txt`） |
| `C:/src/flutter/bin/flutter.bat test test/features/wallet test/features/caibi test/features/finance test/ui` | **`00:30 +675: All tests passed!`，exit 0**（完整输出 `docs/verification/artifacts/2026-09-19/wallet-recharge-withdraw-focused-tests.txt`） |
| `C:/src/flutter/bin/flutter.bat test --timeout 120s`（全量，额外自测） | **`01:52 +3349: All tests passed!`，exit 0** |
| `python scripts/verify_ui_contract.py` | `UI contract drift: PASS (32 components, 372 screens)`，exit 0 |

> 说明：`analyze lib test` 首次运行时 `lib/app_home.dart:3105` 有并发作者（message-outbox）留下的
> `Expected to find '}'` 解析错误；随后其自行修复，最终本表为修复后的真实结果。本人未改该文件。

## 4. 更新过的既有测试（逐条原因）

1. `test/features/wallet/manual_wallet_capabilities_test.dart`（用例「disabling deposits hides payment details but retains open intent」）
   - 原断言 `expect(find.text('查看本次充值'), findsOneWidget)` 断言的正是需求 1 要求**删除**的旧 UI。
   - 改为 `expect(find.text('查看本次充值'), findsNothing)` + `expect(find.byKey(Key('manual-deposit-hero')), findsOneWidget)`：证明申请仍在页面内自动恢复展示（不是删掉入口后信息丢失），断言强度不降低。
2. `test/features/wallet/wallet_official_deposit_test.dart`（用例「open deposit intent shows a validated official QR and exact clipboard」）
   - 原断言 `expect(find.text(syntheticAddress()), findsOneWidget)` 要求完整 34 位地址作为一行文本出现，与需求 2/9 的压缩展示冲突。
   - 改为断言压缩值 `首8…末6` 出现、完整地址不再作为文本出现；**同一用例下方的剪贴板断言 `expect(copied, syntheticAddress())` 未改动**，因此「复制的是完整地址」仍被强制。
3. `test/features/wallet/{manual_recovery,manual_wallet_capabilities,manual_wallet_flow,wallet_actions_ui,wallet_binding_recovery,wallet_compact,wallet_official_deposit,wallet_page_audit,wallet_page_ux,manual_wallet_navigation}_test.dart`
   - 仅 **新增** `WalletEntryStores.disposeAll()`（`setUp` 内 + 1 处用例内），原因：进入态 Store 是**进程内共享**的（键 = 钱包作用域 + 会话 epoch），测试用例复用同一账号作用域，上一个用例的缓存会泄漏到下一个用例的「首次进入/首次失败」断言（真实复现：`wallet_page_ux_test` 的「能力真正加载失败时才提示」在未清空时 `attempts == 0`）。**未删除、未弱化任何既有断言。**
4. 其余既有断言全部保留并通过（含幂等键、金额语义、`manual-payout-amount` 可编辑、报价过期清理、双提交只发一次等）。

## 5. 规格遵从与安全边界

- **未改服务端**、未改账本/金额计算语义、未改权限：幂等键仍由 `BusinessApiClient.newIdempotencyKey()` 生成、`ManualOperationStore` 记录、请求头 `Idempotency-Key` 不变；`createQuote` 仅在金额真的变了（用户改过输入框）时丢弃**未提交**的报价记录并用新幂等键重新报价，已提交订单（`payout`）的重试路径始终复用原键。
- 金融数据不跨账号：网关在作用域变化时抛错（`_WalletEntryGateway.load`），进入态 Store 按 `作用域 + sessionEpoch` 分区、epoch 漂移同步清空缓存；通知栏忽略标记按钱包作用域分区。
- 「不再通知」是**展示层**忽略，不影响服务端申请与订单状态，也不影响「交易记录」等其它入口。
- 每个可交互控件都有可见状态：保存到本地（loading/成功/失败/无权限）、不再通知（loading/成功/失败保留提醒）、确认提现（busy 禁用 + 结果主卡）、重新报价（busy + 报错文案）、余额重试（loading + 成功/失败）。
- 未新增 pubspec 依赖（复用 `photo_manager` / `permission_handler` / `qr_flutter` / `shared_preferences`）。

## 6. 未完成项 / 需要其它文件拥有者的 patch

### 6.1 需求 12「确认有效期 24 小时」——需要**服务端**改动（本人按规则未改服务端）

现状（服务端权威，前端已如实展示并据此校验）：

- `services/business-api/app/core/config.py:83` `wallet_manual_quote_ttl_seconds: int = 300`
- `services/business-api/app/core/config.py:139` `if not 1 <= self.wallet_manual_quote_ttl_seconds <= 3600 ...` （上限 1 小时）
- `services/business-api/app/modules/wallet/manual_payouts.py:69` `... or not timedelta(0) < self.quote_ttl <= timedelta(hours=1)` （策略硬上限 1 小时）
- 过期校验：`manual_payouts.py:285` `if now >= _utc(quote.expires_at): _fail('WALLET_PAYOUT_QUOTE_EXPIRED')`

要做 24 小时，需要服务端同时放宽三处（建议 patch，未应用）：

```diff
--- services/business-api/app/core/config.py
-    wallet_manual_quote_ttl_seconds: int = 300
+    wallet_manual_quote_ttl_seconds: int = 86400
-        if not 1 <= self.wallet_manual_quote_ttl_seconds <= 3600 or not 1 <= self.wallet_deposit_intent_ttl_seconds <= 86400:
+        if not 1 <= self.wallet_manual_quote_ttl_seconds <= 86400 or not 1 <= self.wallet_deposit_intent_ttl_seconds <= 86400:
--- services/business-api/app/modules/wallet/manual_payouts.py
-        if not self.version or not isinstance(self.quote_ttl, timedelta) or not timedelta(0) < self.quote_ttl <= timedelta(hours=1):
+        if not self.version or not isinstance(self.quote_ttl, timedelta) or not timedelta(0) < self.quote_ttl <= timedelta(hours=24):
```

在此 patch 应用前，真实有效期仍是 5 分钟；**前端绝不本地编造 24 小时**（否则会出现「页面说 24 小时、服务端 5 分钟后拒绝」的假承诺）。前端已完成的部分与回归：只展示服务端 `expires_at`、用同一时间点判断过期（`wallet_withdraw_ui_test` 需求 12 两条：23h59m 档位可确认、已过期不可确认）。

### 6.2 需要 finance 文件拥有者（或注册表拥有者）应用的 patch

1. `packages/ui-contracts/changliao-component-registry.json`：`gradient-divider.consumers` 增加本次新增使用点 `ManualWalletPage deposit/payout rows`、`CaibiPage ledger rows`（registry 不在本人持有范围）。若需新增修订块，可参照 `dividerUnification20260919` 的写法记录「钱包/点钻页统一使用共享渐隐分割线」。
2. `lib/features/finance/wallet_entry_store.dart`（**已按并发作者提供的 API 使用，无改动请求**）：
   - 实测 API 与本记录一致；`WalletEntryStores.of` 的 `now` 形参为 `DateTime Function()?`（父 agent 消息里写作 `DateTime? Function() now`），本人按实际签名使用。
   - 建议在文件注释里明确「测试用例之间必须 `WalletEntryStores.disposeAll()`」这一约束（本次已在 10 个既有钱包测试文件的 `setUp` 中落地）。
   - 建议提供生产侧的 `WalletEntryGateway` 实现说明/接线（当前 `BusinessApiClient` 未实现该接口；钱包页与点钻页各自在自有文件内实现了私有网关 `_WalletEntryGateway` / `_CaibiEntryGateway`）。若后续要把账本/红包卡片也提升为会话级缓存，属其持有范围。

### 6.3 其它未完成/受限项

1. 全量 `flutter test` 与 iOS/Android 真机验证由父 agent 最终确认；本次已额外自测全量（3349 条全绿，见 §3），未做真机验证。
2. 二维码「保存到本地」的真实相册写入在真机（Android 9- 存储权限、iOS `photosAddOnly`）未做设备验证；测试已用平台通道 mock 覆盖「申请权限 → 真实 PNG → 写入相册 → 空 id/被拒失败」全链路，`gallery_save_compatibility_test` 继续覆盖声明与旧系统权限策略。
3. 需求 12 的 24 小时（§6.1）；以及服务端若改动 `wallet_manual_quote_ttl_seconds`，前端无需改动（只读 `expires_at`）。
4. 深色/窄屏以 widget 测试断言（颜色解析值、无溢出、`FittedBox`）覆盖，未做逐像素截图对比（与 2026-09-18/19 记录一致）。
