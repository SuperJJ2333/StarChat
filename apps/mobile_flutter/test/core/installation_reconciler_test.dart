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
    expect(
        memory.values.keys.where((k) => k.startsWith('liuhetong.')), isEmpty);
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
