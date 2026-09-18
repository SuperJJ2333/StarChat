# 钱包进入闪烁（按钮闪烁 → 错误提示 → 数据恢复）修复与验证

- 日期：2026-09-18
- 范围：`apps/mobile_flutter/lib/features/finance/**`（+ 其测试）、`docs/verification/`
- 并发边界：`lib/features/wallet/**`、`lib/features/caibi/caibi_page.dart` 由另一 agent 持有，本次**未修改**；需要的改动以「最小 patch」形式附在本文末尾。
- 未提交 commit（由父 agent 统一提交）。

## 0. 结论摘要

| 用户现象 | 根因（file:line） | 修复 |
| --- | --- | --- |
| 每次进入钱包都重新请求、重新进入空态 | 页面 State 每次进入都 `new` 本地 Store / 无条件重发 3+ 个请求 | 新增 `WalletEntryStores`（按钱包作用域 + 会话 epoch 复用共享 Store）+ `WalletEntryStore.enter()`＝缓存优先 + 后台刷新 |
| 余额数字先变 `—` 再恢复 | `manual_wallet_page.dart:283-284` 刷新前先 `pointsAvailable = null` | 页面 patch：刷新前不清空；失败保留旧值 |
| 红色错误条/警告短暂出现 | `manual_wallet_page.dart:194`（`capabilitiesUnavailable = !capabilitiesKnown`，State 重建后 `capabilitiesKnown` 又为 false）、`299`（`pointsError`）、`1080/1145-1146` | 只有「从未成功过」的失败才提示：`WalletLoadPhase.failed` / `WalletEntryState.fatalError` |
| 红包/转账卡片按钮闪一下、旁边闪出「重试」 | `finance_card_store.dart:336-344`（修复前）：**已有明细**时刷新失败也写 `error`，`finance_message_card.dart:86,89` 据此禁用点击并追加重试按钮 | 已在本次修改：有缓存时只置 `stale`（弱信号，`finance_card_store.dart:345-350`），不写 `error` |

## 1. 四项分析（file:line 证据）

### 1.1 页面进入时是否重新创建 Store？——是，两处都会

- `lib/features/wallet/manual_wallet_page.dart:35-36`
  `late final api = ManualWalletApi(widget.client); late final store = ManualOperationStore(widget.client);`
  两者都是 `State` 字段：每次 `Navigator.push(ManualWalletPage(...))`（`wallet_page.dart:83`、`manual_wallet_page.dart:328-330`）都会重建 State，`ManualOperationStore`（含 `SharedPreferences` 初始化）随之重建，`ready` 重新从 `false` 开始。
- `lib/features/wallet/manual_wallet_page.dart:327` `if (busy || !ready) return;`、`:331` 返回总览页时 `await run(refresh)`：从充值/提现页返回也必然重跑一次完整刷新。
- `lib/features/matrix/room_page.dart:581-582`（**未修改，属他 agent 文件**）
  `late final FinanceCardStore _financeCardStore = FinanceCardStore(BusinessFinanceCardGateway(widget.api));`
  → 每次进入房间都新建红包/转账卡片 Store，卡片缓存必然丢失，于是所有卡片都要从空态重新加载一次。
- 前端入口 `lib/app_home.dart:2611`、`:2675` 也是每次导航现构造 `WalletPage(api: ...)`，没有会话级持有者。

### 1.2 每次 init 是否都调网络接口？——是，每次进入至少 3 个请求，且无缓存判定

- `manual_wallet_page.dart:142-159` `initState` → `run(() async { ... })`：
  `walletIntentScope()`/`paymentIntentScope()`（`:143-144`，本地 secure storage，不是网络）→ `store.initialize()` → 草稿读取 → `ready = true` → `refresh()`。
- `manual_wallet_page.dart:162-227` `refresh()` 内：
  `walletConfig()`（`:181`）、`bindingStatus()`（`:196`）、`loadPointsBalance()`（`:225`）→ `getJson('/wallet/balances/me')`（`:289-290`）。全部**无条件**执行，没有任何「缓存够新就跳过」的判断。
- 叠加后台刷新：`balanceRefresh = Timer.periodic(15s)`（`:129`）、`didChangeAppLifecycleState` 恢复即刷新（`:241-249`）。
- `lib/features/caibi/caibi_page.dart:29,35,38-39`：`initState` 无条件重发 `caibiBalance()` + 两次 `ledgerTransactions()`；`:45` `didUpdateWidget` 再发一次。
- 对照：既有 `finance_card_store.dart` 有 `refreshPeriod`（`:136,264-270`）新鲜度判断，钱包页没有对应机制。

### 1.3 loading/error 状态是否覆盖已有数据？——是，这是闪烁的直接原因

- `manual_wallet_page.dart:283-284`（`readPointsBalance()` 开头）
  `pointsAvailable = null; pointsError = null;`
  → 渲染 `:1063` / `:1351` `'当前点钻余额：${pointsAvailable ?? '—'}'` 立刻变 `—`，请求回来再变回数字 = 数字闪烁。
- `manual_wallet_page.dart:299` `pointsError = '点钻余额加载失败，请刷新重试'` → `:1080` / `:1354-1357` 渲染红色 `warningBox` = 错误条闪烁。
- `manual_wallet_page.dart:191-195` 能力配置 catch：`capabilitiesUnavailable = !capabilitiesKnown;` → `:1145-1146` `warningBox('功能状态暂不可用…')`。注释（`:54-56,178-179`）说明「保留上一次已知值」，但 `capabilitiesKnown` 是 State 字段，**State 重建后又是 false**，所以每次进入只要第一次 `walletConfig()` 慢/失败就必然闪一次。
- `manual_wallet_page.dart:335-340` `run()` 的 `busy = true` + `:157` 之前 `ready == false`：`:77-83` `canDeposit/canWithdraw`、`:683/778/1092/1099/1150/1371/1488` 的按钮全部 `onPressed: null`，`:979-982` 刷新按钮变 spinner = 按钮/控件闪烁。
- `finance_card_store.dart:336-344`（**本次已修**）：`catch` 里只要不是 403/404 就写 `error: '加载状态失败，请重试'`，**即使 `detail != null`**；`finance_message_card.dart:85-89` 因此 `enabled=false`（点击失效）且 `retry=true`（卡片下方长出「重试」按钮），下一次成功后一起消失 = 「按钮闪烁 → 错误提示短暂出现 → 数据恢复」。
- `lib/features/caibi/caibi_page.dart:101-124`：`FutureBuilder(future: balance)` 的 future 每次 `_refresh()` 都被替换（`:35`），`snapshot.hasError` 时显示 `'暂不可用'`（`:106-108`），失败即覆盖上一次的好数据；`:133-201` 流水同理（`:147-167` 失败即整块替换为「流水加载失败 + 重试」），`:204-242` 本月汇总也会整块消失。

### 1.4 是否存在 clear/reset 导致 UI 闪烁？——是

- `manual_wallet_page.dart:284`：显式清空 `pointsAvailable`（见 1.3）。
- `manual_wallet_page.dart:235`：`ensureCurrentScope()` 里 `pointsAvailable = null`（账号切换才该清，属正确清理，但与 284 相邻，容易被误解为同一逻辑）。
- `manual_wallet_page.dart:168-177`：`if (depositOp == null) deposit = null;` 等，每次 refresh 都把本地草稿派生的展示态重置。
- `manual_wallet_page.dart:338`：`run()` 里 `message = null`，已展示的提示被清掉。
- `manual_operation_store.dart:10-18`：`initialize()` 每次进入都重读 scope + `SharedPreferences`；`_scope` 初值为 null，未初始化就 `read()/begin()` 会抛 `StateError('账户已切换，请重新打开钱包')`。
- `caibi_page.dart:35-39`：future 重新赋值 = `FutureBuilder` 隐式 reset（无法用 `initialData` 保住旧快照）。
- `finance_card_store.dart:397-407` `_end()`：会话失效/epoch 漂移时把所有条目标记为 `error: '会话已结束'` 并丢弃明细（账号安全所需，保留）。

## 2. 状态机（新增 `WalletLoadPhase`）

```dart
enum WalletLoadPhase { initial, cached, refreshing, success, failed }
```

| 阶段 | 含义 | `hasData` | `refreshing` | `fatalError` |
| --- | --- | --- | --- | --- |
| `initial` | 从未成功加载、也没有缓存（只有 Store 刚创建、未 `enter()` 时） | false | false | false |
| `cached` | 有数据、无请求在飞（可能来自上一次成功，也可能是刷新失败后的回退；`lastError` 可查） | true | false | false |
| `refreshing` | 有请求在飞：有缓存＝后台刷新，无缓存＝首次加载 | 可能 true/false | true | false |
| `success` | 最近一次刷新成功，`data` 为服务端最新值 | true | false | false |
| `failed` | 从未成功过 + 最近一次刷新失败（没东西可展示） | false | false | **true** |

迁移（`enter()`＝页面进入，`refresh()`＝显式/后台刷新；两者共用同一去重逻辑）：

```
初始 ──enter()/refresh()──▶ refreshing
  ├─ 成功 ─▶ success
  └─ 失败 ─▶ failed            (无缓存，唯一需要弹错的失败)

有缓存 ──enter()/refresh()──▶ refreshing（数据保持不变！）
  ├─ 成功 ─▶ success
  └─ 失败 ─▶ cached + lastError   (保留数据、不弹错)

任意状态 ──sessionEpoch 变化──▶ initial（同步丢弃上一个账号的数据）
任意状态 ──retire()（注册表，账号切换）──▶ initial（清空缓存，之后 enter/refresh 为 no-op）
```

对外可见的阶段序列（测试断言的真实序列）：

- 首次进入无缓存：[`refreshing`, `success`]（**不出现 `initial` 空态**）
- 第二次进入有缓存：[`refreshing`, `success`]，期间 `data` 始终非空
- 有缓存刷新失败：[`refreshing`, `cached`]
- 无缓存首次失败：[`refreshing`, `failed`]

## 3. 进入流程图

Store 级（页面无关）：

```
页面 initState
   │
   ├─ WalletEntryStores.of(scope, gateway)   ← 键 = scope + sessionEpoch
   │        │
   │        ├─ 已存在 → 复用同一实例（缓存还在）
   │        └─ 新建（旧 epoch 实例 retire() 清空）
   │
   ├─ store.view.addListener(...)   ← 页面「借用」
   │
   └─ store.enter()
            │
   ┌────────┴─────────┐
   │ hasData == true  │ hasData == false
   ▼                  ▼
 后台 unawaited(refresh())    await refresh()
   │                          │
   │ (phase=refreshing,       ├─ 成功 → success + data
   │  数据原样展示)            └─ 失败 → failed  + lastError（页面弹错/重试）
   │
   ├─ 成功 → success + 新 data（UI 平滑替换）
   └─ 失败 → cached + lastError（保留数据、无错误条、无禁用闪烁，可弱提示）
```

钱包页接入后（本文 patch）：

```
initState
  ├─ walletIntentScope()/paymentIntentScope()      (本地)
  ├─ entry = WalletEntryStores.of(...)             (复用，命中缓存)
  ├─ entry.view.addListener(_applyEntryState)
  ├─ _applyEntryState()                            (能力配置/余额立即就位，不清空)
  ├─ store.initialize() + 草稿读取                  (本地 SharedPreferences)
  ├─ ready = true; setState()                      (按钮不再闪禁用态)
  └─ 后台: entry.enter() → refresh()                (不进入 busy 全禁态)
                    ├─ 成功: 快照更新 → _applyEntryState()
                    └─ 失败: 有缓存→静默保留；无缓存→fatalError 才提示
```

## 4. 缓存 / 错误策略

| 场景 | 数据 | `phase` | `lastError` | 页面允许的行为 |
| --- | --- | --- | --- | --- |
| 首次成功 | 展示新值 | `success` | null | 正常渲染 |
| 首次失败（无缓存） | 无 | `failed` | 有 | 错误文案 + 重试入口（唯一允许弹错的场景） |
| 再次进入（有缓存） | **先展示缓存**，不空转 | `cached`→`refreshing`→`success` | null→失败时非空 | 立即渲染 + 后台刷新；不给整页 spinner/禁用 |
| 刷新失败（有缓存，含弱网超时） | **保留缓存** | 回到 `cached` | 有（可查） | 禁止错误条/弹窗/禁用；只允许弱提示（角标、淡字、「更新于 …」） |
| 接口恢复 | 替换为新值 | `success` | 清空 | 正常渲染 |
| 账号切换（epoch 变化） | **同步清空** | `initial` | null | 重新走首次加载（金融数据绝不跨账号展示） |
| 请求在飞时再次进入 | 不变 | 不重复通知 | — | 复用同一 future，不重复打网络 |

## 5. 红 → 绿证据（真实输出）

实现文件：`apps/mobile_flutter/lib/features/finance/wallet_entry_store.dart`
测试文件：`apps/mobile_flutter/test/features/finance/wallet_entry_state_test.dart`

红 1（实现文件暂缺，证明测试确实指向缺失行为）：

```
$ flutter test test/features/finance/wallet_entry_state_test.dart
  test/features/finance/wallet_entry_state_test.dart:253:18: Error: Undefined name 'WalletLoadPhase'.
  test/features/finance/wallet_entry_state_test.dart:268:26: Error: 'WalletEntryStore' isn't a type.
00:00 +0 -1: Some tests failed.
  Failing tests:
    .../wallet_entry_state_test.dart: loading .../wallet_entry_state_test.dart
```

绿 1：

```
$ flutter test test/features/finance/wallet_entry_state_test.dart
00:00 +1: 钱包进入态（缓存优先 + 后台刷新） 1. 首次进入（无缓存、接口成功）：只加载一次并最终 success，不出现空态闪烁
00:00 +2: ... 2. 第二次进入（有缓存）：立即拿到 cached 数据，后台刷新到 success，期间数据从不为空
00:00 +3: ... 3. 弱网进入（刷新超时但有缓存）：数据仍在、phase 不为 failed、无致命错误
00:00 +4: ... 4. 接口失败但有缓存：同上，且全程不产生需要 UI 弹错的错误信号
00:00 +5: ... 5. 接口恢复：下一次刷新成功后 phase = success 且数据为新值
00:00 +6: ... 6. Store 复用：同一钱包作用域跨两次进入是同一实例，缓存不丢
00:00 +7: ... 7. 账号切换：被持有的旧 Store 在下次刷新前丢弃缓存，绝不跨账号展示
00:00 +8: ... 8. 并发进入/刷新合并为一次请求，状态未变化时不重复通知
00:00 +9: ... 9. 只读状态视图：值相等不视为变化，致命错误只属于无缓存的首次失败
00:00 +9: All tests passed!
```

红 2（卡片 Store：有缓存时刷新失败仍写 `error`）：

```
$ flutter test test/features/finance/finance_card_store_test.dart
  Error: The getter 'stale' isn't defined for the type 'FinanceCardState'.
  Error: The getter 'hasData' isn't defined for the type 'FinanceCardState'.
00:00 +0 -1: Some tests failed.
```

绿 2（新增 3 条 + 既有 25 条回归）：

```
$ flutter test test/features/finance/finance_card_store_test.dart
00:00 +25: a forced refresh keeps cached detail while loading without an empty state
00:00 +26: a failed refresh with cache recovers its stale flag on the next success
00:00 +27: a first load failure without any cache still surfaces a retryable error
00:00 +28: All tests passed!
```

门禁（真实输出）：

```
$ cd apps/mobile_flutter && C:/src/flutter/bin/flutter.bat analyze lib test
Analyzing 2 items...
No issues found! (ran in 5.0s)

$ C:/src/flutter/bin/flutter.bat test test/features/finance
00:02 +63: All tests passed!
```

（`test/features/finance` 共 63 条：既有 5 个测试文件 + 本次新增 9 条钱包进入态 + 3 条卡片缓存策略。全量 `flutter test --timeout 120s` 由父 agent 统一执行。）

## 6. 对外 API 签名（并发页面 agent 直接使用）

`lib/features/finance/wallet_entry_store.dart`：

```dart
enum WalletLoadPhase { initial, cached, refreshing, success, failed }

@immutable
final class WalletEntryState {
  const WalletEntryState({
    this.phase = WalletLoadPhase.initial,
    this.data,
    this.lastError,
    this.updatedAt,
  });
  final WalletLoadPhase phase;
  final Map<String, dynamic>? data;   // 最近一次成功快照；失败时不清空
  final Object? lastError;            // 最近一次失败原因（可查，非「非空即致命」）
  final DateTime? updatedAt;          // 最近一次成功的本机时间
  bool get hasData;                   // data != null
  bool get refreshing;                // phase == refreshing
  bool get fatalError;                // phase == failed && lastError != null ← 只有它允许弹错
}

abstract interface class WalletEntryGateway {
  int get sessionEpoch;                            // 账号切换即变化
  Future<Map<String, dynamic>> load();             // 一次权威快照；抛错=本次刷新失败
}

final class WalletEntryStore {
  WalletEntryStore({required WalletEntryGateway gateway, String scope = '',
      DateTime Function()? now});
  ValueListenable<WalletEntryState> get view;      // 订阅入口（ValueListenableBuilder）
  WalletEntryState get state;                      // 当前只读视图
  bool get disposed;
  Future<void> enter();                            // 进入：有缓存立即返回+后台刷新；无缓存等首次加载
  Future<void> refresh();                          // 显式/后台刷新；在飞时复用同一 future
  void retire();                                   // 账号切换：清空缓存并停用
  void dispose();                                  // 仅宿主调用
}

final class WalletEntryStores {                     // 进程内共享注册表（键 = scope + epoch）
  static WalletEntryStore of({required String scope, required WalletEntryGateway gateway,
      DateTime Function()? now});
  static void disposeScope(String scope);
  static void disposeAll();
  @visibleForTesting static int get instanceCount;
}
```

契约保证（与父 agent 约定逐条对应）：

- 有缓存时 `phase` 只可能是 `cached`/`refreshing`/`success`，**绝不经过 `initial`**；
- 刷新失败且有缓存：`phase` 回到 `cached`，`fatalError == false`（`lastError` 仍可查）；
- 首次失败（无缓存）：`phase == failed` 且 `fatalError == true`；
- 只在状态真正变化时 `notify`（`WalletEntryState` 实现了值相等，`ValueNotifier` 用 `==` 去重）。

**谁持有、谁 dispose**

- 持有者：会话级宿主（`AppHome` / 注册表 `WalletEntryStores`）。`WalletEntryStores.of()` 返回共享实例，键含 `sessionEpoch`，因此换账号后自动新建、旧实例被 `retire()` 清空缓存。
- 页面：只 `view.addListener/removeListener`，**不得**在 `State.dispose()` 里 `dispose()` Store。
- 释放：退出登录时可选调用 `WalletEntryStores.disposeAll()`（不是正确性的必要条件：epoch 变化已在下次进入时清空旧缓存；不做只是进程内多留几个空壳实例）。

`FinanceCardState` 增量（`finance_card_store.dart`，保持向后兼容）：

```dart
final bool stale;              // 已有明细 + 最近一次刷新失败 → 仅弱提示用
bool get hasData => detail != null;
// error 语义收窄为：只有「没有任何明细」的失败才写 error（页面据此禁用/重试）
```

## 7. 页面最小 patch（充值/提现页，由并发 agent 应用）

> 说明：`lib/features/wallet/**` 与 `lib/features/caibi/caibi_page.dart` 不在本次编辑范围，以下 patch **未经编译验证**（无法在不触碰他 agent 文件的前提下 `analyze`）。Store 本体与测试已通过第 5 节门禁。

### 7.1 `lib/features/wallet/manual_wallet_page.dart`

P1 新增 import（第 6 行 `import '../../core/business_api_client.dart';` 之后）：

```dart
import '../finance/wallet_entry_store.dart';
```

P2 文件末尾追加网关：

```dart
/// 钱包进入快照网关：把「能力配置 + 点钻余额」合并成一份权威快照。
/// 绑定状态/草稿仍走既有 ManualWalletApi/ManualOperationStore，不放进快照，
/// 因此它们的失败语义（会话变化等）保持不变。
final class _WalletEntryGateway implements WalletEntryGateway {
  _WalletEntryGateway(this.client);
  final BusinessApiClient client;
  @override
  int get sessionEpoch => client.sessionEpoch;
  @override
  Future<Map<String, dynamic>> load() async {
    final scope = await client.walletIntentScope();
    final config = await client.walletConfig();
    final balances = await client.getJson('/wallet/balances/me',
        expectedWalletScope: scope);
    return {'config': config, 'caibi_available': balances['caibi_available']};
  }
}
```

P3 State 字段（第 36 行 `late final store = ManualOperationStore(widget.client);` 之后）：

```dart
  /// 钱包进入态共享 Store（缓存优先 + 后台刷新）。持有者是会话级
  /// WalletEntryStores；页面只借用，dispose() 里只 removeListener。
  late final _entryGateway = _WalletEntryGateway(widget.client);
  WalletEntryStore? entry;
```

P4 `initState`：把 `run(() async { ... });`（第 142-159 行整块）替换为：

```dart
    unawaited(_bootstrap());
  }

  /// 进入钱包：**先展示缓存 → 再后台刷新**（不再「先清空再等接口」）。
  Future<void> _bootstrap() async {
    walletScope = await widget.client.walletIntentScope();
    paymentScope = await widget.client.paymentIntentScope();
    final shared =
        WalletEntryStores.of(scope: walletScope!, gateway: _entryGateway);
    entry = shared;
    shared.view.addListener(_applyEntryState);
    _applyEntryState(); // 命中缓存：能力配置/余额立刻就位，不等网络
    await store.initialize();
    bindingOp = await store.read('binding');
    depositOp = await store.read('deposit');
    quoteOp = await store.read('quote');
    payoutOp = await store.read('payout');
    if (!mounted) return;
    address.text = bindingOp?['address'] as String? ?? '';
    amount.text = (widget.section == ManualWalletSection.deposit
            ? depositOp
            : quoteOp)?['amount'] as String? ??
        '';
    ready = true; // 到这里才允许交互（本地读，毫秒级）
    setState(() {});
    // 网络部分放后台：有缓存时不再整页进入 busy 禁用态，按钮不闪。
    await shared.enter();
    if (!mounted) return;
    await run(refresh, cacheFirst: shared.state.hasData);
  }

  /// 命中缓存或后台刷新落地时，用快照刷新能力配置与点钻余额。
  /// **没有数据时直接返回**：绝不把已有显示清空（闪烁的根因）。
  void _applyEntryState() {
    final snapshot = entry?.state.data;
    if (snapshot == null) return;
    final config = snapshot['config'];
    if (config is Map) {
      depositEnabled = config['funding_enabled'] == true;
      payoutEnabled = config['manual_payout_enabled'] == true;
      executionEnabled = config['manual_payout_execution_enabled'] == true;
      conversionEnabled = config['conversion_enabled'] == true;
      pointsPayoutEnabled =
          config['caibi_payout_enabled'] == true && conversionEnabled;
      capabilitiesKnown = true;
      capabilitiesUnavailable = false;
      addressOnly = config['user_auth_mode'] == 'address_only';
    }
    final balance = snapshot['caibi_available'];
    if (balance is String) {
      pointsAvailable = pointsText(balance);
      pointsError = null;
    }
    if (mounted) setState(() {});
  }
```

P5 `refresh()`：第 178-195 行（能力配置 try/catch 整块）替换为：

```dart
    // 能力配置 + 点钻余额：统一走进入态 Store（缓存优先 + 后台刷新）。
    // 有缓存时刷新失败只留弱失败信号：保留数据、不显示错误条、不闪。
    await entry?.refresh();
    _applyEntryState();
    final entryState = entry?.state;
    capabilitiesUnavailable = entryState?.fatalError ?? false; // 只有从未成功过才提示
    if (entryState != null && entryState.fatalError) {
      pointsError = '点钻余额加载失败，请刷新重试';
    } else if (entryState?.hasData ?? false) {
      pointsError = null;
    }
```

并把第 223-226 行整块：

```dart
    if (widget.section == ManualWalletSection.payout ||
        widget.section == ManualWalletSection.overview) {
      await loadPointsBalance();
    }
```

替换为：

```dart
    // 余额已由 entry 快照应用（见 _applyEntryState），此处不再单独请求，
    // 避免「先清空再等接口」造成的余额/错误条闪烁。
```

P6 `readPointsBalance()`（第 282-301 行整块，供「重新加载余额」按钮使用）：

```dart
  Future<void> readPointsBalance() async {
    final shared = entry;
    if (walletScope == null || shared == null) {
      throw StateError('账户尚未就绪');
    }
    await ensureCurrentScope(); // 作用域校验仍在，失败照旧报错
    await shared.refresh();     // 缓存优先：成功才更新，失败保留旧值
    final snapshot = shared.state.data;
    final value = snapshot?['caibi_available'];
    if (value is String) {
      pointsAvailable = pointsText(value);
      pointsError = null;
      return;
    }
    // 只有「从未成功过/快照缺字段」才提示；有缓存时上面已经 return。
    pointsAvailable = null;
    pointsError = '点钻余额加载失败，请刷新重试';
  }
```

P7 `run()`（第 334-369 行）加一个参数，让「有缓存的后台刷新」不进入整页禁用态：

```dart
  Future<void> run(Future<void> Function() action,
      {bool cacheFirst = false}) async {
    if (busy) return;
    if (!cacheFirst) {
      setState(() {
        busy = true;
        message = null;
        messageIsWarning = false;
      });
    }
    try {
      if (ready) await ensureCurrentScope();
      await action();
    } catch (error) {
      // 有缓存的静默刷新失败：保留数据，不弹错误（弱提示由 entry 状态给出）。
      if (cacheFirst && (entry?.state.hasData ?? false)) return;
      messageIsWarning = true;
      // ...（其余不变）
    } finally {
      if (mounted) {
        otp.clear();
        signature.clear();
        oldSignature.clear();
        if (!cacheFirst) setState(() => busy = false);
      }
    }
  }
```

P8 `dispose()`（第 669-679 行）内追加一行（**不要** dispose 共享 Store）：

```dart
    entry?.view.removeListener(_applyEntryState);
```

不需要改 `wallet_page.dart` / `app_home.dart`：复用由 `WalletEntryStores` 的 `scope + sessionEpoch` 键完成；可选在退出登录处调用 `WalletEntryStores.disposeAll()`。

### 7.2 `lib/features/caibi/caibi_page.dart`（可选，点钻页同源问题）

问题：`:32-40` 每次进入重发 3 个请求并替换 future，`:101-124` / `:133-201`（本月汇总 `:204-242`）的 `FutureBuilder` 在失败时用 `'暂不可用'`/「流水加载失败」覆盖上一份好数据。

最小接法：

```dart
// 1) 文件末尾
final class _CaibiEntryGateway implements WalletEntryGateway {
  _CaibiEntryGateway(this.api);
  final BusinessApiClient api;
  Map<String, dynamic>? _recent, _monthly;
  @override
  int get sessionEpoch => api.sessionEpoch;
  @override
  Future<Map<String, dynamic>> load() async {
    final balance = await api.caibiBalance(); // 权威余额：失败→整份回退缓存
    final now = DateTime.now();
    var recentFailed = false, monthlyFailed = false;
    _recent = await _keep(api.ledgerTransactions(limit: 3),
            onError: () => recentFailed = true) ??
        _recent;
    _monthly = await _keep(
            api.ledgerTransactions(startAt: DateTime(now.year, now.month, 1), limit: 100),
            onError: () => monthlyFailed = true) ??
        _monthly;
    return {
      'balance': balance['balance'],
      'recent': _recent ?? const {},
      'recent_failed': recentFailed,
      'monthly': _monthly ?? const {},
      'monthly_failed': monthlyFailed,
    };
  }

  Future<Map<String, dynamic>?> _keep(Future<Map<String, dynamic>> read,
      {required void Function() onError}) async {
    try {
      return await read;
    } catch (_) {
      onError();
      return null;
    }
  }
}

// 2) State 内
WalletEntryStore? entry;
Future<void> _bootstrap() async {
  final api = widget.api;
  if (api == null) return;
  final shared = WalletEntryStores.of(
      scope: await api.walletIntentScope(), gateway: _CaibiEntryGateway(api));
  entry = shared;
  shared.view.addListener(_onEntryState);
  await shared.enter();      // 有缓存立即返回，刷新在后台
}
void _onEntryState() {
  if (mounted) setState(() {});
}
// initState: unawaited(_bootstrap());  dispose: entry?.view.removeListener(_onEntryState);

// 3) 三个 FutureBuilder 改为读 entry?.state：
//    余额：hasData ? data['balance'] : (fatalError ? '暂不可用' : '--')
//    流水：hasData ? data['recent'] : 旧行为；data['recent_failed']==true 时显示
//          「流水加载失败 + 重试」但**不隐藏余额**
//    本月汇总：hasData ? data['monthly'] : ''
//    重试按钮：onPressed: () => entry?.refresh()
```

（若只做最小改动：把 `_balanceHero` 一处改为读 `entry.state` 即可消除「余额 → 暂不可用 → 余额」的闪烁；流水块可后续再做。）

## 8. 剩余风险 / 未覆盖

1. **页面 patch 未编译验证**：`manual_wallet_page.dart` / `caibi_page.dart` 属于并发 agent 的文件，本次只提供 patch 文本。应用后必须重跑 `flutter analyze lib test` + `test/features/wallet`（父 agent 全量）。
2. **`FinanceCardState.error` 语义收窄影响面**：`finance_message_entry.dart:96` 仍用 `state.error != null` 作为「不进入卡片」的判据。有缓存 + 刷新失败时 `error` 不再写入，于是点击会进入详情页（详情页自己重新拉权威明细）。这是刻意的（卡片不再禁用点击），但改变了旧行为，需要真机确认。
3. **`stale` 弱提示尚无 UI**：`FinanceCardState.stale` 已就绪（`finance_message_card.dart` 暂未使用），符合「弱提示可选、绝不能闪」的要求；若要角标，只需在卡片上加一个不改变布局的淡色标记。
4. **卡片 Store 仍按房间页重建**（`room_page.dart:581`）：红包/转账卡片每次进房间仍会重新加载（`loading` 只叠加不覆盖数据，故已有明细的卡片不闪；没有明细的卡片仍会显示「加载中」再出数据）。彻底修复需把 `FinanceCardStore` 提升到会话级（例如放进 `WalletEntryStores` 同级的注册表），涉及他 agent 正在改的 `room_page.dart`，本次未动。建议作为后续任务：`FinanceCardStore` 的键同样是 `sessionEpoch`，复用模式与本次一致。
5. **后台刷新与用户操作并发**（patch 的 `cacheFirst` 路径不再置 `busy`）：后台刷新期间用户可以进入充值/提现页；草稿读写以幂等键为准、`refresh()` 会重新读取草稿，未发现脏写路径，但这是本次唯一放宽的并发护栏，需在真机回归一次「进入钱包后立刻点充值」。
6. **点钻页三路合并为一个快照**（7.2）：余额失败会整份回退缓存；流水失败用 `recent_failed` 标记单独提示，不隐藏余额。若产品要求余额与流水各自独立阶段，需拆成两个 Store。
7. **弱网无缓存的首屏**：`failed` + 红色错误条（要求允许），弱提示/重试按钮由页面渲染，未做自动重试退避（沿用既有 15s 定时器）。
8. **`Map.unmodifiable` 只冻结顶层**：快照内嵌的 `config`/列表仍是原对象；页面只读展示，业务判定仍由业务 API 权威。
