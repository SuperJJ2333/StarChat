# 钱包离线（微信级加载模型）真机复验 — Mi 6（2026-09-19）

**目的：** 验证用户报告 #1「钱包页面下的各个子页面的缓存还是没有更新 / 无网或者断网情况，无法加载绑定钱包，无法进入充值/提现页」在当前构建上的真实表现，并区分"已修好"和"仍未覆盖"。

**设备与构建：**
- 设备 `cbd0156b`（小米 6，Android 9），包名 `com.liuhetong.mobile`
- 已安装构建：`versionName=0.3.96`，`lastUpdateTime=2026-09-19 08:17:31`（即含 `05fabb3a` 钱包离线修复的 debug 构建）
- 操作方式：`adb shell input tap / keyevent`、`adb exec-out screencap`；离线用 `adb shell cmd connectivity airplane-mode enable`，并已用 `dumpsys connectivity`（`Active default network: none`）与 `ping`（`Network is unreachable`）确认真正断网

**方法：** 先联网走一遍（写入快照）→ 开飞行模式 → `am force-stop` + 冷启动（最坏情况）→ 逐页进入并截图；最后恢复网络。全部截图见 `docs/verification/artifacts/2026-09-19/`（该目录按仓库约定被 `.gitignore` 忽略，属临时验证产物；本文件给出文件名与观察结论，命令可复现）。

---

## 1. 结论：用户症状已修复的部分

| 页面 | 在线基线 | 断网冷启动 | 判定 |
|---|---|---|---|
| 消息列表 | — | `wallet-07-offline-coldstart.png`：会话列表正常渲染 + 「网络不可用，点击重试 / 联网后自动重试」提示，无 FATAL/ANR | ✅ 离线可进 |
| 钱包主页（绑定地址 + 余额 + 进行中申请入口） | `wallet-04-online-entry.png`：`TDt7Qe…F89t`、`已绑定`、`当前点钻余额 44.39`、`查看已有提现申请` | `wallet-11-offline-wallet.png`：**同样的绑定地址、`已绑定`、余额 44.39、顶部申请入口全部在位，无错误文案** | ✅ **这就是用户主诉的修复**（断网冷启动仍能进入并展示绑定钱包信息） |
| 充值页 | `wallet-05-online-deposit.png`：步骤 1 表单 | `wallet-12-offline-deposit.png`：步骤 1 完整渲染（手续费 0.00 USDT / TRON TRC20 / 下一步），无错误态 | ✅ 离线可进 |
| 点钻页（彩币） | `caibi-01-online.png`：余额 44.39 + 最近流水 3 条 | `caibi-02-offline.png`：余额 44.39 + 同一批流水 —— **与在线一致** | ✅ 离线可进（见 §3 更正） |
| 「我」页资料 | `wallet-03-me-root.png` | `wallet-10-offline-me-layout.png`：昵称/畅聊号/签名仍在（身份缓存生效） | ✅ |

## 2. 仍未覆盖：提现页的「申请状态卡」断网消失（新发现）

> **后续（同一会话，提交 `3362e4b8`）：已修复。** 新增 `lib/features/wallet/manual_payout_status_store.dart`（按 `walletIntentScope + payout id` 的本地快照，显式九字段非密白名单；读取拒绝未登记字段/id 不符/损坏内容；作用域每次访问重新校验），`ManualWalletPage.refresh()` 改为「先渲染快照 → 后台刷新 → 失败保留」。测试 `test/features/wallet/manual_wallet_payout_status_cache_test.dart` 6 例 + 反向对照，`flutter test test/features/wallet` 113 例全绿。**注意：该修复尚未在真机复验**（本节 A/B 证据是修复前的现状），真机复验需要重新构建安装。

受控 A/B（**同一个待处理提现申请**，`payout` 操作记录确认仍存在，见 §2.2）：

| 截图 | 网络 | 观察 |
|---|---|---|
| `withdraw-A-offline.png` | 飞行模式 | 余额 `44.39`（缓存）✅、步骤条 ✅、提现金额 `10.000000`；**底部状态卡缺失** |
| `withdraw-C-online-refreshed.png` | 联网点击右上刷新 | 同样内容 **+ 状态卡**：时钟图标、`10.000000 USDT`、`管理员人工付款处理中` |

**根因（file:line）：** 提现状态对象只来自网络：

- `lib/features/wallet/manual_wallet_page.dart:312-315`
  ```dart
  if (widget.section == ManualWalletSection.payout &&
      payoutOp?['id'] != null) {
    payout = await api.payout(payoutOp!['id'] as String);
  }
  ```
  断网时该 await 抛错 → `payout` 保持 `null`；而状态卡渲染条件是 `if (payout != null) ...`（`:1945-1973`），于是状态卡整块消失。
- 已持久化的只有"申请操作记录"（`ManualOperationStore`，键 `flutter.wallet.manual.v1:<scope>:payout`），**状态对象 `ManualPayout` 本身没有本地快照**。

**判定：** 这正是用户所说「提现页（余额/申请/状态）」里"申请状态"那一项没被缓存覆盖。最小改动方向：把最后一次成功的 `ManualPayout` 按 `<scope>:payout:<id>` 落本地（与 `ManualOperationStore` 同层或钱包快照内），进入时先渲染、后台刷新覆盖；失败不覆盖。

**实施约束（为什么不是一行改动）：** 不能直接往 `ManualOperationStore` 里塞状态对象——它的 `save` 有安全白名单（`lib/features/wallet/manual_operation_store.dart:43-68`，仅允许 `key/amount/version/id/quote_id/address/method/confirm_key/funding_asset`），写入 `status`/`review_reason`/`settlement_txid` 会抛 `ArgumentError('Secret or unsupported operation metadata')`。正确做法是新增独立的状态快照 store（自带显式非密字段白名单 + 账号作用域校验 + 账号切换丢弃），因此本轮只取证、不改动该资金边界。

### 2.2 证据：申请记录确实还在本地（排除"操作被我点没了"）
```
adb shell run-as com.liuhetong.mobile cat .../shared_prefs/FlutterSharedPreferences.xml
→ flutter.wallet.manual.v1:https://liuhetong888.com:<uuid>:payout
→ flutter.wallet.entry.v1.https://liuhetong888.com:<uuid>
→ flutter.wallet.entry.v1.https://liuhetong888.com:<uuid>#caibi
```
即断网时 `payoutOp != null`（步骤条也确实停在"到账"），缺失的仅是网络取回的状态对象。

## 3. 过程更正（不掩盖错误判定）

首轮断网测试里，点钻页显示「暂不可用 / 余额加载失败，请重试 / 流水加载失败」（`caibi-00-offline-empty-cache.png`），一度被当作缺陷。随后做了受控复验：**先联网打开点钻页一次**（`caibi-01-online.png`，成功写入 `wallet.entry.v1.<scope>#caibi` 快照），再断网冷启动重进（`caibi-02-offline.png`）——余额与流水**全部从缓存渲染**。

结论：首轮现象是"从未成功过（无本地数据）→ 允许报错"的模型例外，**不是缺陷**；点钻页已符合 L1/L2。该更正同时说明"必须先联网成功一次"是快照类修复的前提，验收时不能跳过。

## 4. 其他观察（非本次验收目标）

- 充值页填金额 →「下一步」后进入受截图保护的窗口：此时 `adb exec-out screencap` 返回 0 字节（应用侧 `FLAG_SECURE`，见 `lib/features/matrix/screen_capture_protection.dart`），返回 3 次后回到「我」页且截图恢复正常，与"钱包→充值→转账（收款地址/二维码）"的返回栈一致。因此**该步的界面无法截图取证**（属产品有意的防截屏），离线可达性只能间接判断。
- 冷启动离线与恢复联网全程 `logcat` 无 `FATAL EXCEPTION` / `ANR in com.liuhetong.mobile`。

## 5. 复现命令与"再上机"的注意事项

**本轮上机时的一个硬约束（写给下一个复验的人）：** 机上是仓库稳定签名身份的交付构建，`flutter build apk --debug` 产出的 raw Gradle APK（`build/app/outputs/flutter-apk/app-standard-debug.apk`）**装不上去**：

```
adb install -r app-standard-debug.apk
→ INSTALL_FAILED_UPDATE_INCOMPATIBLE: Package com.liuhetong.mobile signatures do not match previously installed version
```

`adb uninstall` 会连带清掉本机会话与所有本地快照（正是本验收依赖的东西，还会把用户登出），因此**没有**执行。要真机复验 §2 的修复，必须按 `docs/runbooks/android-apk-rebuild.md` 走稳定签名身份的打包流程再安装。

**本轮已获得的替代证据：** `flutter test test/features/wallet` 113 例全绿（含新增 6 例与反向对照）、`flutter analyze lib/features/wallet test/features/wallet` 无问题、全量 `flutter test` **3432 例全部通过**（退出码 0）。

```powershell
$adb = 'E:\software\platform-tools\adb.exe'   # 或 PATH 中的 adb
# 离线
& $adb shell cmd connectivity airplane-mode enable
& $adb shell settings get global airplane_mode_on      # 1
& $adb shell dumpsys connectivity | Select-String 'Active default network'   # none
# 冷启动
& $adb shell am force-stop com.liuhetong.mobile
& $adb shell am start -n com.liuhetong.mobile/.MainActivity
# 取证
& $adb exec-out screencap -p > offline.png
# 恢复
& $adb shell cmd connectivity airplane-mode disable
```

**遗留：** 提现状态卡（§2）需要代码改动后才能断网显示；本文件只记录真机现状与证据，不代表该项已完成。
