import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('chatflow/ios_secure_session');
  const plugin = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final nativeCalls = <MethodCall>[];
  final pluginCalls = <MethodCall>[];
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    nativeCalls.clear();
    pluginCalls.clear();
    messenger.setMockMethodCallHandler(native, (call) async {
      nativeCalls.add(call);
      return call.method == 'read' ? 'same-value' : null;
    });
    messenger.setMockMethodCallHandler(plugin, (call) async {
      pluginCalls.add(call);
      return call.method == 'read' ? 'same-value' : null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(plugin, null);
    debugDefaultTargetPlatformOverride = null;
  });
  test('only database and business session use safe native Keychain bridge',
      () async {
    final store = FlutterSecureKeyValueStore();
    for (final key in [
      'liuhetong.matrix_database_key.v1',
      'liuhetong.business_session.v1'
    ]) {
      expect(await store.read(key), 'same-value');
      await store.write(key, 'same-value');
    }
    await store.read('liuhetong.encrypted_recovery_key');
    await store.read('liuhetong.registration_device_key.v1');
    expect(nativeCalls.length, 4);
    expect(pluginCalls.length, 2);
  });
  test(
      'locked Keychain error propagates; never generates or writes replacement database key',
      () async {
    messenger.setMockMethodCallHandler(native, (call) async {
      nativeCalls.add(call);
      throw PlatformException(code: '-25308');
    });
    final store = SecureSessionStore();
    await expectLater(
        store.matrixDatabaseKey(), throwsA(isA<PlatformException>()));
    expect(nativeCalls.map((c) => c.method), ['read']);
    expect(pluginCalls, isEmpty);
  });
  test('Android retains existing secure storage path', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(
        await FlutterSecureKeyValueStore()
            .read('liuhetong.matrix_database_key.v1'),
        'same-value');
    expect(nativeCalls, isEmpty);
    expect(pluginCalls.length, 1);
  });
}
