import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/installation_container_probe.dart';
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

final class _FakeProbe implements InstallationContainerProbe {
  _FakeProbe({this.hasPrevious = false, this.error});
  final bool hasPrevious;
  final Object? error;
  var calls = 0;

  @override
  Future<bool> hasPreviousMatrixStore() async {
    calls++;
    if (error != null) throw error!;
    return hasPrevious;
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

  test('标记已存在时不清除也不探测', () async {
    final memory = await _retainedKeychain();
    final before = Map<String, String>.from(memory.values);
    final probe = _FakeProbe(hasPrevious: true);

    final outcome = await InstallationReconciler(
            marker: _FakeMarker(registered: true),
            probe: probe,
            store: SecureSessionStore(memory))
        .reconcile();

    expect(outcome, InstallationResetOutcome.notNeeded);
    expect(memory.values, before);
    expect(probe.calls, 0);
  });

  test('标记缺失且容器无库文件时清除全部遗留并写入标记', () async {
    final memory = await _retainedKeychain();
    final marker = _FakeMarker();

    final outcome = await InstallationReconciler(
            marker: marker,
            probe: _FakeProbe(),
            store: SecureSessionStore(memory))
        .reconcile();

    expect(outcome, InstallationResetOutcome.cleared);
    expect(
        memory.values.keys.where((k) => k.startsWith('liuhetong.')), isEmpty);
    expect(marker.registerCalls, 1);
  });

  test('覆盖升级：容器仍有加密库时只播种标记，一个键都不删', () async {
    final memory = await _retainedKeychain();
    final before = Map<String, String>.from(memory.values);
    final marker = _FakeMarker();

    final outcome = await InstallationReconciler(
            marker: marker,
            probe: _FakeProbe(hasPrevious: true),
            store: SecureSessionStore(memory))
        .reconcile();

    expect(outcome, InstallationResetOutcome.adopted);
    expect(memory.values, before);
    expect(marker.registerCalls, 1);
  });

  test('标记读取失败时不清除也不写标记', () async {
    final memory = await _retainedKeychain();
    final before = Map<String, String>.from(memory.values);
    final marker = _FakeMarker(readError: StateError('prefs unavailable'));
    final probe = _FakeProbe();

    final outcome = await InstallationReconciler(
            marker: marker, probe: probe, store: SecureSessionStore(memory))
        .reconcile();

    expect(outcome, InstallationResetOutcome.failed);
    expect(memory.values, before);
    expect(marker.registerCalls, 0);
    expect(probe.calls, 0);
  });

  test('探测器抛错时不清除也不写标记', () async {
    final memory = await _retainedKeychain();
    final before = Map<String, String>.from(memory.values);
    final marker = _FakeMarker();

    final outcome = await InstallationReconciler(
            marker: marker,
            probe: _FakeProbe(error: StateError('container unreadable')),
            store: SecureSessionStore(memory))
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
            marker: marker,
            probe: _FakeProbe(),
            store: SecureSessionStore(memory))
        .reconcile();

    expect(outcome, InstallationResetOutcome.failed);
    expect(marker.registerCalls, 0);
    expect(marker.registered, isFalse);
  });

  test('清除失败后解除故障再次核对，重试成功并写入标记', () async {
    final memory = await _retainedKeychain();
    memory.deleteErrors['liuhetong.business_session.v1'] =
        StateError('keychain unavailable');
    final marker = _FakeMarker();
    final reconciler = InstallationReconciler(
        marker: marker, probe: _FakeProbe(), store: SecureSessionStore(memory));

    expect(await reconciler.reconcile(), InstallationResetOutcome.failed);
    expect(marker.registerCalls, 0);

    memory.deleteErrors.clear();
    expect(await reconciler.reconcile(), InstallationResetOutcome.cleared);
    expect(marker.registerCalls, 1);
    expect(
        memory.values.keys.where((k) => k.startsWith('liuhetong.')), isEmpty);
  });

  test('带槽密钥删除失败时保留枚举入口，重试会清除全部遗留', () async {
    final memory = await _retainedKeychain();
    final scopedDatabaseKey = memory.values.keys.firstWhere(
      (key) => key.startsWith('liuhetong.matrix_database_key.v1.'),
    );
    memory.deleteErrors[scopedDatabaseKey] =
        StateError('scoped keychain unavailable');
    final marker = _FakeMarker();
    final reconciler = InstallationReconciler(
      marker: marker,
      probe: _FakeProbe(),
      store: SecureSessionStore(memory),
    );

    expect(await reconciler.reconcile(), InstallationResetOutcome.failed);
    expect(marker.registerCalls, 0);
    expect(
      memory.values.containsKey('liuhetong.matrix_account_slots.v1'),
      isTrue,
    );

    memory.deleteErrors.clear();
    expect(await reconciler.reconcile(), InstallationResetOutcome.cleared);
    expect(marker.registerCalls, 1);
    expect(
      memory.values.keys.where((key) => key.startsWith('liuhetong.')),
      isEmpty,
    );
  });

  test('标记写入失败报告为未落定', () async {
    final memory = await _retainedKeychain();
    final marker = _FakeMarker(writeError: StateError('prefs write failed'));

    final outcome = await InstallationReconciler(
            marker: marker,
            probe: _FakeProbe(),
            store: SecureSessionStore(memory))
        .reconcile();

    expect(outcome, InstallationResetOutcome.failed);
  });
}
