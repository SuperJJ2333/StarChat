# iOS 卸载重装登录失败（L07）修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 iOS 卸载重装后的登录不再因钥匙串残留而失败（L07），并使重装后的本地状态与 Android 卸载后一致。

**Architecture:** 在随卸载一起消失的存储（`SharedPreferences`）中保存一个安装标记。启动时标记缺失即判定为全新安装，在打开加密库之前一次性清除全部钥匙串遗留（各账号槽的密钥与绑定、账号注册表、当前槽指针、业务会话、注册设备键、遗留 token 键），清除成功后再写入标记。标记读取失败时不清理也不写标记；清除未完成时不写标记。

**Tech Stack:** Flutter 3.44 / Dart 3.12；`shared_preferences`（已有依赖）；`crypto`（已有，用于既有 SHA256 槽标识）；测试用 `flutter_test`。

**Spec:** [docs/superpowers/specs/2026-09-11-ios-reinstall-installation-generation-design.md](../specs/2026-09-11-ios-reinstall-installation-generation-design.md)
**ADR:** [docs/adr/0068-installation-generation-reset.md](../../adr/0068-installation-generation-reset.md)
**任务记录:** [docs/workflow/tasks/2026-09-11-ios-reinstall-l07.md](../../workflow/tasks/2026-09-11-ios-reinstall-l07.md)

## Global Constraints

- 不修改**服务端**任何代码；不改 E2EE 算法、密钥恢复流程或单设备会话策略。
- **不修改** `MatrixClientFactory.continuityMetadata` 的完整性守卫，**不修改** `SecureSessionStore.selectMatrixAccount` 的注册表冲突判定。
- **标记读取失败 → 既不清除也不写标记**（不确定时绝不抹掉有效会话）。
- **清除未完成 → 不写标记**（否则残留被永久化，下次启动不再重试）。
- **注册表损坏 → 仍然清除**（此时不确定性已不存在，只影响后缀枚举方式）。
- `reconcile()` 必须在任何读取钥匙串遗留的动作之前执行，即早于 `BusinessApiClient`、`MatrixClientFactory` 的构造与 `matrixFactory.create()`。
- 工作目录固定为 `apps/mobile_flutter`；所有命令在该目录下执行。
- 注释与文档用中文；代码标识符保持英文，与仓库现有风格一致。
- 每个任务以一条失败用例开始，最小实现转绿后提交。
- 受影响回归：`test/core/session_store_test.dart`、`test/features/matrix/matrix_client_factory_test.dart`、`test/features/matrix/account_client_selection_test.dart`、`test/core/session_bootstrap_controller_test.dart`、`test/core/ios_secure_session_test.dart`；共享逻辑改动后运行 `flutter analyze`。

---

### Task 1: 安装标记存储

**Files:**
- Create: `apps/mobile_flutter/lib/core/installation_marker.dart`
- Test: `apps/mobile_flutter/test/core/installation_marker_test.dart`

**Interfaces:**
- Consumes: 无
- Produces:
  - `abstract interface class InstallationMarkerStore { Future<bool> isRegistered(); Future<void> register(); }`
  - `final class SharedPreferencesInstallationMarker implements InstallationMarkerStore`，构造参数为 `SharedPreferences`，静态常量 `SharedPreferencesInstallationMarker.key = 'changliao.installation.v1'`

- [ ] **Step 1: 写失败用例**

创建 `test/core/installation_marker_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/installation_marker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('无标记时报告为未注册', () async {
    SharedPreferences.setMockInitialValues({});
    final marker =
        SharedPreferencesInstallationMarker(await SharedPreferences.getInstance());
    expect(await marker.isRegistered(), isFalse);
  });

  test('空值不算已注册', () async {
    SharedPreferences.setMockInitialValues(
        {SharedPreferencesInstallationMarker.key: ''});
    final marker =
        SharedPreferencesInstallationMarker(await SharedPreferences.getInstance());
    expect(await marker.isRegistered(), isFalse);
  });

  test('注册后持久化为非空值且可再次读出', () async {
    SharedPreferences.setMockInitialValues({});
    final marker =
        SharedPreferencesInstallationMarker(await SharedPreferences.getInstance());
    await marker.register();
    expect(await marker.isRegistered(), isTrue);
    // 重新读取同一个键，确认落盘的是非空值而不是仅存在于内存。
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(SharedPreferencesInstallationMarker.key), isNotEmpty);
  });
}
```

- [ ] **Step 2: 运行用例确认失败**

Run: `flutter test test/core/installation_marker_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'liuhetong_mobile' ... installation_marker.dart`（文件尚不存在，编译失败）

- [ ] **Step 3: 写最小实现**

创建 `lib/core/installation_marker.dart`：

```dart
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// 安装世代标记。存放位置必须随应用卸载一起消失：iOS 落 NSUserDefaults、
/// Android 落应用数据，两端都会在卸载时清除。钥匙串不会，因此不能用它承载
/// 这个判断。
abstract interface class InstallationMarkerStore {
  Future<bool> isRegistered();
  Future<void> register();
}

final class SharedPreferencesInstallationMarker
    implements InstallationMarkerStore {
  SharedPreferencesInstallationMarker(this._preferences);

  static const key = 'changliao.installation.v1';

  final SharedPreferences _preferences;

  @override
  Future<bool> isRegistered() async {
    final value = _preferences.getString(key);
    return value != null && value.isNotEmpty;
  }

  @override
  Future<void> register() async {
    // 写入随机值而不是布尔值：空串或空白值不能被误读成"已注册"。
    final value = base64UrlEncode(
      List<int>.generate(24, (_) => Random.secure().nextInt(256)),
    );
    if (!await _preferences.setString(key, value)) {
      throw StateError('Installation marker was not persisted');
    }
  }
}
```

- [ ] **Step 4: 运行用例确认通过**

Run: `flutter test test/core/installation_marker_test.dart`
Expected: PASS，`All tests passed!`

- [ ] **Step 5: 提交**

```bash
git add apps/mobile_flutter/lib/core/installation_marker.dart apps/mobile_flutter/test/core/installation_marker_test.dart
git commit -m "feat(mobile): add installation generation marker"
```

---

### Task 2: `SecureSessionStore.clearInstallation()`

**Files:**
- Modify: `apps/mobile_flutter/lib/core/session_store.dart`（在 `_clearMatrixIdentityUnlocked`（第 324-344 行）之后、`clear()`（第 346 行）之前插入新方法；在类顶部常量区第 96 行之后追加常量）
- Test: `apps/mobile_flutter/test/core/installation_clear_test.dart`

**Interfaces:**
- Consumes: `SecureSessionStore`、`_AccountScopedSecureStore`（同文件私有类，其 `activeKey` / `registryKey` 为 `static const`）、`SecureKeyValueStore.raw`
- Produces: `Future<void> SecureSessionStore.clearInstallation()`

- [ ] **Step 1: 写失败用例**

创建 `test/core/installation_clear_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'account_chat_store_test.dart' show binding;
import 'session_store_test.dart' show MemorySecureKeyValueStore;

const _home = 'https://matrix.example';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('清除覆盖全部账号槽与固定元数据键', () async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    await store.saveSession(accessToken: 'a', refreshToken: 'r');
    await store.registrationDeviceKey();
    await store.selectMatrixAccount(_home, '@a:test');
    await store.saveMatrixBinding(binding('@a:test', 'device-A'));
    await store.matrixDatabaseKey();
    await store.selectMatrixAccount(_home, '@b:test');
    await store.saveMatrixBinding(binding('@b:test', 'device-B'));
    await store.matrixDatabaseKey();
    expect(memory.values.keys.where((k) => k.startsWith('liuhetong.')), isNotEmpty);

    await store.clearInstallation();

    expect(memory.values.keys.where((k) => k.startsWith('liuhetong.')), isEmpty);
  });

  test('无后缀的遗留键一并清除', () async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    await memory.write('liuhetong.matrix_database_key.v1', 'legacy-key');
    await memory.write('liuhetong.matrix_local_binding.v1', '{"version":2}');

    await store.clearInstallation();

    expect(memory.values.containsKey('liuhetong.matrix_database_key.v1'), isFalse);
    expect(memory.values.containsKey('liuhetong.matrix_local_binding.v1'), isFalse);
  });

  test('注册表损坏不阻断清除，仍按可识别后缀删除', () async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    final suffix = 'a' * 64;
    // 结构非法但含有合法槽标识：解析必须失败，回退仍须命中。
    await memory.write('liuhetong.matrix_account_slots.v1', '{"$suffix":');
    await memory.write('liuhetong.matrix_database_key.v1.$suffix', 'scoped-key');

    await store.clearInstallation();

    expect(memory.values.containsKey('liuhetong.matrix_database_key.v1.$suffix'),
        isFalse);
    expect(memory.values.containsKey('liuhetong.matrix_account_slots.v1'), isFalse);
  });

  test('单个键删除失败时抛出首个错误且不静默通过', () async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    await memory.write('liuhetong.business_session.v1', 'value');
    memory.deleteErrors['liuhetong.business_session.v1'] =
        StateError('keychain unavailable');

    await expectLater(store.clearInstallation(), throwsStateError);
  });
}
```

- [ ] **Step 2: 运行用例确认失败**

Run: `flutter test test/core/installation_clear_test.dart`
Expected: FAIL — `The method 'clearInstallation' isn't defined for the type 'SecureSessionStore'`

- [ ] **Step 3: 写最小实现**

在 `lib/core/session_store.dart` 的常量区（`_matrixClearTombstoneValue` 之后）追加：

```dart
  /// 按槽隔离的键名。清空一次安装时要连同它们的全部槽后缀一起删除。
  static const _scopedKeyNames = <String>[
    _matrixDatabaseKey,
    _matrixBindingKey,
    _recoveryKey,
    _diagnosticSaltKey,
    _matrixClearTombstoneKey,
  ];

  /// 独立于槽的固定键。ADR-0063 之前的单账号遗留键用空后缀覆盖。
  static const _slotIndependentKeys = <String>[
    _AccountScopedSecureStore.activeKey,
    _AccountScopedSecureStore.registryKey,
    _sessionKey,
    _registrationDeviceKey,
    _legacyAccessKey,
    _legacyRefreshKey,
  ];

  static final _hashToken = RegExp(r'[a-f0-9]{64}');
```

在 `_clearMatrixIdentityUnlocked` 之后、`clear()` 之前插入：

```dart
  /// 全新安装时清除上一安装遗留的全部钥匙串状态。
  ///
  /// 这里必须作用于 `raw`：要删除的正是作用域指针与注册表本身，不能先经过
  /// 作用域间接层。加密库文件已随沙盒消失，因此删除全部槽不会丢失可读数据。
  Future<void> clearInstallation() =>
      _runMatrixIdentityOperation(_clearInstallationUnlocked);

  Future<void> _clearInstallationUnlocked() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attemptDelete(String key) async {
      try {
        await _storage.raw.delete(key);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    for (final suffix in await _installationSlotSuffixes()) {
      for (final name in _scopedKeyNames) {
        await attemptDelete(suffix.isEmpty ? name : '$name.$suffix');
      }
    }
    for (final key in _slotIndependentKeys) {
      await attemptDelete(key);
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  /// 候选槽后缀：空后缀（ADR-0063 之前的单账号遗留）加上注册表中出现的槽。
  /// 注册表损坏不得阻断清除——此时"全新安装"这个判断已经成立，损坏只影响
  /// 枚举方式，退化为从原始值中提取全部 64 位十六进制串。
  Future<Set<String>> _installationSlotSuffixes() async {
    final suffixes = <String>{''};
    final encoded =
        await _storage.raw.read(_AccountScopedSecureStore.registryKey);
    if (encoded == null) return suffixes;
    try {
      suffixes.addAll((await _storage.slots()).values);
    } catch (_) {
      suffixes.addAll(
          _hashToken.allMatches(encoded).map((match) => match.group(0)!));
    }
    return suffixes;
  }
```

- [ ] **Step 4: 运行用例确认通过**

Run: `flutter test test/core/installation_clear_test.dart test/core/session_store_test.dart test/core/account_chat_store_test.dart`
Expected: PASS，`All tests passed!`

- [ ] **Step 5: 提交**

```bash
git add apps/mobile_flutter/lib/core/session_store.dart apps/mobile_flutter/test/core/installation_clear_test.dart
git commit -m "feat(mobile): clear every keychain-retained identity for a new installation"
```

---

### Task 3: `InstallationReconciler`

**Files:**
- Create: `apps/mobile_flutter/lib/core/installation_reconciler.dart`
- Test: `apps/mobile_flutter/test/core/installation_reconciler_test.dart`
- Modify: `apps/mobile_flutter/test/features/matrix/ios_reinstall_continuity_test.dart`（整体替换：从"断言修复前行为"改为"断言 L07 已消失"）

**Interfaces:**
- Consumes: `InstallationMarkerStore.isRegistered`/`register`（Task 1）、`SecureSessionStore.clearInstallation`（Task 2）
- Produces:
  - `enum InstallationResetOutcome { notNeeded, cleared, failed }`
  - `final class InstallationReconciler { InstallationReconciler({required InstallationMarkerStore marker, required SecureSessionStore store}); Future<InstallationResetOutcome> reconcile(); }`

- [ ] **Step 1: 写失败用例**

创建 `test/core/installation_reconciler_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/installation_marker.dart';
import 'package:liuhetong_mobile/core/installation_reconciler.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'account_chat_store_test.dart' show binding;
import 'session_store_test.dart' show MemorySecureKeyValueStore;

const _home = 'https://matrix.example';

final class _FakeMarker implements InstallationMarkerStore {
  _FakeMarker({this.registered = false, this.readError, this.writeError});
  bool registered;
  final Object? readError;
  final Object? writeError;
  var registerCalls = 0;

  @override
  Future<bool> isRegistered() async {
    if (readError != null) throw readError!;
    return registered;
  }

  @override
  Future<void> register() async {
    registerCalls++;
    if (writeError != null) throw writeError!;
    registered = true;
  }
}

Future<MemorySecureKeyValueStore> _retainedKeychain() async {
  final memory = MemorySecureKeyValueStore();
  final store = SecureSessionStore(memory);
  await store.saveSession(accessToken: 'a', refreshToken: 'r');
  await store.selectMatrixAccount(_home, '@a:test');
  await store.saveMatrixBinding(binding('@a:test', 'device-A'));
  await store.matrixDatabaseKey();
  return memory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('标记已存在时不清除任何键', () async {
    final memory = await _retainedKeychain();
    final before = Map<String, String>.from(memory.values);

    final outcome = await InstallationReconciler(
            marker: _FakeMarker(registered: true),
            store: SecureSessionStore(memory))
        .reconcile();

    expect(outcome, InstallationResetOutcome.notNeeded);
    expect(memory.values, before);
  });

  test('标记缺失时清除全部遗留并写入标记', () async {
    final memory = await _retainedKeychain();
    final marker = _FakeMarker();

    final outcome = await InstallationReconciler(
            marker: marker, store: SecureSessionStore(memory))
        .reconcile();

    expect(outcome, InstallationResetOutcome.cleared);
    expect(memory.values.keys.where((k) => k.startsWith('liuhetong.')), isEmpty);
    expect(marker.registerCalls, 1);
  });

  test('标记读取失败时不清除也不写标记', () async {
    final memory = await _retainedKeychain();
    final before = Map<String, String>.from(memory.values);
    final marker = _FakeMarker(readError: StateError('prefs unavailable'));

    final outcome = await InstallationReconciler(
            marker: marker, store: SecureSessionStore(memory))
        .reconcile();

    expect(outcome, InstallationResetOutcome.failed);
    expect(memory.values, before);
    expect(marker.registerCalls, 0);
  });

  test('清除失败时不写标记，保留下次启动重试的机会', () async {
    final memory = await _retainedKeychain();
    memory.deleteErrors['liuhetong.business_session.v1'] =
        StateError('keychain unavailable');
    final marker = _FakeMarker();

    final outcome = await InstallationReconciler(
            marker: marker, store: SecureSessionStore(memory))
        .reconcile();

    expect(outcome, InstallationResetOutcome.failed);
    expect(marker.registerCalls, 0);
    expect(marker.registered, isFalse);
  });

  test('标记写入失败报告为未落定', () async {
    final memory = await _retainedKeychain();
    final marker = _FakeMarker(writeError: StateError('prefs write failed'));

    final outcome = await InstallationReconciler(
            marker: marker, store: SecureSessionStore(memory))
        .reconcile();

    expect(outcome, InstallationResetOutcome.failed);
  });
}
```

**同一个步骤内，把端到端复现用例反转成目标行为。** 该文件当前断言的是修复前的
异常（证明 L07 的来源），现在改为断言它已消失。整体替换
`test/features/matrix/ios_reinstall_continuity_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/installation_marker.dart';
import 'package:liuhetong_mobile/core/installation_reconciler.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import '../../core/account_chat_store_test.dart' show binding;
import '../../core/session_store_test.dart' show MemorySecureKeyValueStore;
import 'matrix_client_factory_test.dart' show LogoutTrackingClient;

const _home = 'https://matrix.example';

MatrixClientFactory _factory(SecureSessionStore store) => MatrixClientFactory(
      sessionStore: store,
      homeserver: Uri.parse(_home),
      supportDirectoryPath: () async => '/private/support',
      clientMigrator: (_, __) async {},
      opener: (
          {required clientName,
          required databasePath,
          required cipher}) async =>
          LogoutTrackingClient(clientName),
    );

final class _Marker implements InstallationMarkerStore {
  _Marker({this.registered = false, this.readError});
  bool registered;
  final Object? readError;
  var registerCalls = 0;

  @override
  Future<bool> isRegistered() async {
    if (readError != null) throw readError!;
    return registered;
  }

  @override
  Future<void> register() async {
    registerCalls++;
    registered = true;
  }
}

/// iOS 卸载会删掉应用沙盒（含 SQLCipher 库）但保留钥匙串，因此账号注册表、
/// 绑定与数据库密钥仍在，而库已不存在。重装后登录必须能正常建立新的加密设备，
/// 而不是被判成完整性损坏（登录流程的 account_storage 阶段 = L07）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<MemorySecureKeyValueStore> retainedKeychain() async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    await store.selectMatrixAccount(_home, '@a:test');
    await store.saveMatrixBinding(binding('@a:test', 'device-A'));
    await store.matrixDatabaseKey();
    return memory;
  }

  test('iOS 重装后清除遗留，连续性检查不再抛错', () async {
    final memory = await retainedKeychain();
    final store = SecureSessionStore(memory);
    final factory = _factory(store);

    // 清除之前，重装留下的绑定确实会让空库被判成损坏。
    await expectLater(
        factory.continuityMetadata(await factory.create()),
        throwsA(isA<StateError>().having((error) => error.message, 'message',
            'Matrix continuity identity is unavailable')));

    final outcome = await InstallationReconciler(
            marker: _Marker(), store: store)
        .reconcile();
    expect(outcome, InstallationResetOutcome.cleared);

    final next = await factory.create();
    final metadata = await factory.continuityMetadata(next);
    expect(metadata.isLoggedIn, isFalse);
    expect(metadata.userId, isNull);
    expect(metadata.deviceId, isNull);
  });

  test('重装后首次登录不再阻断在 account_storage 阶段', () async {
    final memory = await retainedKeychain();
    final store = SecureSessionStore(memory);
    await InstallationReconciler(marker: _Marker(), store: store).reconcile();
    final factory = _factory(store);
    final matrix = MatrixSdkE2eeClient(
      LogoutTrackingClient('liuhetong_mobile'),
      homeserver: Uri.parse(_home),
      suspendClient: factory.suspend,
      resumeClient: factory.create,
      selectClientAccount: factory.selectAccount,
      readContinuityMetadata: factory.continuityMetadata,
    );

    await matrix.selectAccount('@a:test', Uri.parse(_home));

    expect(matrix.userId, isNull);
  });

  test('Android 式干净重装：清除为空操作且检查不抛错', () async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    final factory = _factory(store);

    final outcome = await InstallationReconciler(
            marker: _Marker(), store: store)
        .reconcile();
    expect(outcome, InstallationResetOutcome.cleared);
    expect(memory.values.keys.where((k) => k.startsWith('liuhetong.')), isEmpty);

    final metadata = await factory.continuityMetadata(await factory.create());
    expect(metadata.isLoggedIn, isFalse);
  });

  test('标记读取失败时不清理，完整性守卫仍按原样失败关闭', () async {
    final memory = await retainedKeychain();
    final store = SecureSessionStore(memory);
    final factory = _factory(store);

    final outcome = await InstallationReconciler(
            marker: _Marker(readError: StateError('prefs unavailable')),
            store: store)
        .reconcile();

    expect(outcome, InstallationResetOutcome.failed);
    await expectLater(
        factory.continuityMetadata(await factory.create()),
        throwsA(isA<StateError>().having((error) => error.message, 'message',
            'Matrix continuity identity is unavailable')));
  });
}
```

- [ ] **Step 2: 运行用例确认失败**

Run: `flutter test test/core/installation_reconciler_test.dart test/features/matrix/ios_reinstall_continuity_test.dart`
Expected: FAIL — 两个文件都因 `Couldn't resolve the package 'liuhetong_mobile' ... installation_reconciler.dart`（实现文件尚不存在）而无法编译。这正是本次修复的失败用例：端到端那条用例断言的就是 L07 不再发生。

- [ ] **Step 3: 写最小实现**

创建 `lib/core/installation_reconciler.dart`：

```dart
import 'installation_marker.dart';
import 'session_store.dart';

/// 启动时安装世代核对的结果。
enum InstallationResetOutcome {
  /// 标记已存在：同一安装的延续，未做任何清理。
  notNeeded,

  /// 全新安装：遗留已清除且标记已写入。
  cleared,

  /// 状态未落定：标记读取失败、清除失败或标记写入失败。调用方应继续启动，
  /// 但知道本次运行的本地状态没有得到保证。
  failed,
}

/// 让应用能区分"同一安装的延续"与"全新安装但钥匙串有残留"。
///
/// 必须在任何读取钥匙串遗留的动作之前运行：它决定了那些遗留是否还成立。
final class InstallationReconciler {
  InstallationReconciler({required this.marker, required this.store});

  final InstallationMarkerStore marker;
  final SecureSessionStore store;

  Future<InstallationResetOutcome> reconcile() async {
    final bool registered;
    try {
      registered = await marker.isRegistered();
    } catch (_) {
      // 不确定是否为全新安装时，绝不抹掉可能是有效的会话与密钥。
      return InstallationResetOutcome.failed;
    }
    if (registered) return InstallationResetOutcome.notNeeded;
    try {
      await store.clearInstallation();
    } catch (_) {
      // 清除未完成就不写标记，否则残留会被永久化，下次启动不再重试。
      // 部分清除是安全的：任一残留都不会让状态比修复前更差。
      return InstallationResetOutcome.failed;
    }
    try {
      await marker.register();
    } catch (_) {
      // 清除已生效，但标记未落定，下次启动会幂等地重跑一次清除。
      return InstallationResetOutcome.failed;
    }
    return InstallationResetOutcome.cleared;
  }
}
```

- [ ] **Step 4: 运行用例确认通过**

Run: `flutter test test/core/installation_reconciler_test.dart test/features/matrix/ios_reinstall_continuity_test.dart`
Expected: PASS，`All tests passed!`（5 + 4 = 9 个用例）。端到端那条由红转绿即为验收 A01。

- [ ] **Step 5: 提交**

```bash
git add apps/mobile_flutter/lib/core/installation_reconciler.dart apps/mobile_flutter/test/core/installation_reconciler_test.dart apps/mobile_flutter/test/features/matrix/ios_reinstall_continuity_test.dart
git commit -m "feat(mobile): reconcile the installation generation at startup"
```

---

### Task 4: 启动装配与回归验收

**Files:**
- Modify: `apps/mobile_flutter/lib/main.dart:1-33`（新增两个 import；在第 33 行 `final store = SecureSessionStore();` 之后插入核对调用）
- Modify: `docs/workflow/tasks/2026-09-11-ios-reinstall-l07.md`（验收台账与测试证据）

**Interfaces:**
- Consumes: `InstallationReconciler`、`InstallationResetOutcome`（Task 3）、`SharedPreferencesInstallationMarker`（Task 1）
- Produces: 无对外接口。本任务不新增测试文件——A01/A02 的用例已在 Task 3 由红转绿。
  `main.dart` 是组合根，仓库现有测试均不覆盖它，因此这里不做伪红步骤，只做接线、
  跑回归与静态检查。

- [ ] **Step 1: 接线 `main.dart`**

在 `lib/main.dart` 的 import 区（第 11 行 `import 'core/session_store.dart';` 之后）加入：

```dart
import 'core/installation_marker.dart';
import 'core/installation_reconciler.dart';
```

并在第 33 行 `final store = SecureSessionStore();` 之后插入：

```dart
  // 必须在打开加密库、构造业务客户端之前：iOS 的钥匙串不随卸载删除，重装后
  // 会留下上一安装的密钥与绑定，而它们保护的加密库已随沙盒消失。
  final installationReset = await InstallationReconciler(
    marker: SharedPreferencesInstallationMarker(
      await SharedPreferences.getInstance(),
    ),
    store: store,
  ).reconcile();
  if (installationReset == InstallationResetOutcome.failed && kDebugMode) {
    debugPrint('[installation] generation reset did not settle');
  }
```

`kDebugMode` 与 `debugPrint` 来自 `package:flutter/foundation.dart`。第 3 行的
`package:flutter/cupertino.dart` 通常会传递它们；运行 Step 2 的 `flutter analyze`，
若报未定义标识符，则在 import 区补一行：

```dart
import 'package:flutter/foundation.dart';
```

- [ ] **Step 2: 运行受影响回归与静态检查**

Run:
```bash
flutter test test/core/installation_marker_test.dart test/core/installation_clear_test.dart test/core/installation_reconciler_test.dart test/core/session_store_test.dart test/core/account_chat_store_test.dart test/core/ios_secure_session_test.dart test/core/session_bootstrap_controller_test.dart test/features/matrix/matrix_client_factory_test.dart test/features/matrix/account_client_selection_test.dart test/features/matrix/ios_reinstall_continuity_test.dart
flutter analyze
```
Expected: 全部 PASS；`flutter analyze` 无新增 issue。

- [ ] **Step 3: 提交**

```bash
git add apps/mobile_flutter/lib/main.dart
git commit -m "fix(mobile): reset the installation generation before opening the store"
```

- [ ] **Step 4: 更新任务记录**

在 `docs/workflow/tasks/2026-09-11-ios-reinstall-l07.md` 的验收台账中把 A01–A05 标记为已实现，
并追加测试证据（命令、真实退出码、用例数）。A06 保持"未完成"，需 iPhone 8 安装含本修复的
构建后复测。提交：

```bash
git add docs/workflow/tasks/2026-09-11-ios-reinstall-l07.md
git commit -m "docs: record the installation-generation fix evidence"
```

---

## 计划自审

- **规格覆盖**：§3.2 四个部件 → Task 1/2/3/4；§3.3 清除范围 → Task 2 的
  `_scopedKeyNames` + `_slotIndependentKeys` + 空后缀；§3.4 三条失败规则 →
  Task 3 的五个用例逐条对应；§3.6 不做的事 → Global Constraints 明确禁止；
  §4 的 T1–T8 → T1/T2 在 Task 3 的端到端用例（与实现同任务，方能真正由红转绿），
  T3/T6/T7 在 Task 3 的协调器用例，T4/T5/T8 在 Task 2。
- **任务边界**：Task 4 不含伪红步骤。`main.dart` 是组合根，仓库现有测试不覆盖它；
  把端到端用例放在 Task 4 会让它在 Task 3 完成后立即变绿，"先失败"就成了假动作。
  因此端到端用例归入 Task 3，Task 4 只做接线、回归与静态检查。
- **占位符**：无 TBD/TODO；每个代码步骤都有完整可粘贴代码。
- **类型一致性**：`isRegistered`/`register`/`clearInstallation`/`reconcile`/
  `InstallationResetOutcome` 在四个任务中名称与签名一致；
  `SharedPreferencesInstallationMarker.key` 在 Task 1 定义、Task 1 测试使用。
- **未覆盖项**：A06 真机确认无法由本计划完成，已在任务记录中标为未完成。
