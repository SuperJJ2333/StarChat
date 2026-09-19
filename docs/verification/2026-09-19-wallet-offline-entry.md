# 钱包各子页面：断网可用 + 进入不闪（2026-09-19）

**用户报告**

1. 「钱包页面下的各个子页面的缓存还是没有更新」——具体为：绑定地址与钱包信息、充值页（收款地址/金额/本次申请）、提现页（余额/申请/状态）、充值或提现的申请状态。
2. 「每次进入页面都会闪烁加载，显示错误警告，然后恢复正常。」
3. 「无网或者断网情况，无法加载绑定钱包，无法进入充值/提现页。」

## 根因

两条独立的缺陷叠在一起，都违反微信级加载模型的第 1、4 条：

1. **进入态快照只活在进程内存里。** `WalletEntryStore` 的缓存是内存态（`WalletEntryStores` 进程内注册表，键 `scope#sessionEpoch`），App 一重启就没了。于是**每次冷启动后**进入钱包/点钻/充值/提现，都必然重走「无缓存 → 首次加载失败 → `fatalError` 弹错 → 有网后恢复」，这正是「闪烁加载 + 错误警告 + 恢复正常」。
2. **绑定状态只走网络。** `_ManualWalletPageState.activeBinding` 要求 `bindingFresh == true`，而 `bindingFresh` 只在 `refresh()` 里 `binding = await api.bindingStatus()`（`manual_wallet_page.dart:280`）**成功之后**才置真。断网时该请求抛错 → `bindingFresh` 永远是 false → `activeBinding == false` → `canDeposit` / `canWithdraw` 全为 false（`:96-102`）→ 绑定地址显示成「请先绑定你的钱包地址」、充值/提现入口不可点，同时 `run()` 把异常画成错误提示。这就是「断网无法加载绑定钱包、进不去充值/提现页」。
3. 附带：`refresh()` 只捕获进入态刷新，`bindingStatus`/`depositIntent`/`payout` 等失败会冒泡到 `run()`；`_bootstrap` 只在 `shared.state.hasData` 为真时才按缓存优先处理，而内存态在冷启动时必然为假。

## 改动

| 文件 | 改动 |
|---|---|
| `lib/features/finance/wallet_entry_snapshot_store.dart`（新增） | 本地快照存储：`WalletEntrySnapshot{data, savedAt}` + 接口 `read`（**同步**，首帧可用）/`write`/`clear`/`clearAll`；`SharedPreferencesWalletEntrySnapshotStore`（键前缀 `wallet.entry.v1.<scope>`，`open()` 时全部读进内存）+ `InMemoryWalletEntrySnapshotStore`（测试/降级）+ 进程级 `WalletEntrySnapshotStores.ensureLoaded()` |
| `lib/features/finance/wallet_entry_store.dart` | 构造时**同步**从快照水合（`_hydrateFromSnapshot()`）；刷新成功后写回快照（写盘失败不算刷新失败）；epoch 漂移时清除该作用域快照；`WalletEntryStores.snapshots`（默认取进程级共享实例）随 `of()` 注入页面——**页面接线不变**；`disposeAll()` 清空全部快照 |
| `lib/app_home.dart` | `_startHomeResources()` 里 `WalletEntrySnapshotStores.ensureLoaded()`，失败不阻塞启动 |
| `lib/features/wallet/manual_wallet_api.dart` | `ManualBindingStatus.toJson()`：绑定状态可原样还原（服务端字段名） |
| `lib/features/wallet/manual_wallet_page.dart` | 进入态网关把 `binding` 一并放进快照；`_applyEntryState()` 在 `bindingFresh == false` 时用快照种下绑定状态并置 `bindingFresh = true`（断网也「已绑定」、入口可用）；新增 `hasLocalData`，resume 与从子页返回的刷新路径改为 `cacheFirst: hasLocalData`（有本地数据就不显示整页 busy、失败不弹错） |

**边界与取舍（明确记录）：** 快照里只有展示所需的服务端数据（能力配置、余额、绑定状态；点钻页另有最近流水与月度汇总），**不含** access token、验证码、恢复密钥或任何凭据——凭据仍只在 `SecureSessionStore`；快照写在应用私有 SharedPreferences，键含账号作用域（`<origin>:<subject>`，点钻为 `<scope>#caibi`），账号切换（epoch 变化）立即清除，金融数据绝不跨账号展示。绑定地址此前已经会随 `ManualOperationStore` 草稿落盘，本次不新增泄露面。若后续要求「金融数据一律加密落盘」，可把该 Store 换到 SQLCipher（与 Matrix 库同一套能力），接口不变。

**已知未覆盖（下一轮）：** 进行中的充值/提现**申请状态**（`depositIntent`/`payout`/`payoutQuote`）仍然只走网络，断网时页面可用但看不到上次的申请状态文本；需要为这三个对象加一层「原始 JSON 槽位缓存」（模型已有 `fromJson`，无需改模型）。

## 测试（红 → 绿）

- `test/features/finance/wallet_entry_state_test.dart` 新增第 10-13 条：构造即水合（首帧有数据、不发请求）、断网进入保留数据且 `fatalError == false`、成功后写盘 + epoch 漂移清盘、注册表自动注入共享快照存储。**红**：实现前 4 条因类型不存在编译失败；**绿**：13/13 通过（原有 1-9 条缓存优先契约不回归）。
- `test/features/wallet/wallet_entry_cache_test.dart` 新增「断网 + 本地快照」页面级用例：假客户端所有钱包请求抛错，断言**绑定地址 `T***123` 可见、显示「已绑定」、余额 88.88 可见、无「功能状态暂不可用」/「点钻余额加载失败」/弹窗，且点「充值」真的进入充值页（步骤指示器出现）**。
- 门禁：`flutter analyze lib test` 干净；`test/features/wallet + finance + caibi` 177 通过；全量 **+3369 通过**（较改动前 +5 = 4 条 Store 用例 + 1 条页面用例）。

## 真机验证

待出包后在 Mi 6 上验证（`adb install -r`，保持 `firstInstallTime`）：
1. 飞行模式进入「我 → 钱包」→ 应显示上次的绑定地址与余额，充值/提现入口可点，无错误提示；
2. 关闭飞行模式 → 应自动后台刷新到最新；
3. 杀进程冷启动 → 不再出现「闪烁 + 错误警告」；
4. 每次进入各子页面（钱包/点钻/充值/提现）记录是否出现加载闪烁或错误条。
