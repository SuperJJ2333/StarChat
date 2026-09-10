import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'session_store_test.dart' show MemorySecureKeyValueStore;

const _home = 'https://matrix.example';
MatrixLocalBinding binding(String user, String device) => MatrixLocalBinding(
    version: 2,
    matrixUserId: user,
    deviceId: device,
    homeserver: _home,
    databaseGeneration: 'generation-$user',
    ed25519Fingerprint: 'fingerprint-$user');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('corrupt registry without active pointer fails closed', () async {
    final memory = MemorySecureKeyValueStore();
    await memory.write('liuhetong.matrix_account_slots.v1', '{broken');
    final store = SecureSessionStore(memory);
    await expectLater(store.matrixDatabaseKey(), throwsFormatException);
  });
  test('iOS scoped database key retains device-local native storage route',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('chatflow/ios_secure_session');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return 'protected-key';
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final name = 'liuhetong.matrix_database_key.v1.${'a' * 64}';
    expect(await FlutterSecureKeyValueStore().read(name), 'protected-key');
    expect(calls.single.arguments, {'key': name});
  });
  test('legacy A -> B -> A preserves independent keys bindings and recovery',
      () async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    final aKey = await store.matrixDatabaseKey();
    await store.saveMatrixBinding(binding('@a:test', 'device-A'));
    await store.saveEncryptedRecoveryKey('recovery-A');
    await (store as dynamic).selectMatrixAccount(_home, '@b:test');
    final bScope = await (store as dynamic).matrixStorageScope();
    expect(bScope, matches(RegExp(r'^[a-f0-9]{64}$')));
    final bKey = await store.matrixDatabaseKey();
    expect(bKey, isNot(aKey));
    expect(await store.matrixBinding(), isNull);
    expect(await store.encryptedRecoveryKey(), isNull);
    await store.saveMatrixBinding(binding('@b:test', 'device-B'));
    await store.saveEncryptedRecoveryKey('recovery-B');
    await (store as dynamic).selectMatrixAccount(_home, '@a:test');
    expect(await (store as dynamic).matrixStorageScope(), '');
    expect(await store.matrixDatabaseKey(), aKey);
    expect((await store.matrixBinding())?.deviceId, 'device-A');
    expect(await store.encryptedRecoveryKey(), 'recovery-A');
    final restarted = SecureSessionStore(memory);
    await (restarted as dynamic).selectMatrixAccount(_home, '@b:test');
    expect(await restarted.matrixDatabaseKey(), bKey);
    expect(await restarted.encryptedRecoveryKey(), 'recovery-B');
    expect(memory.attemptedDeletes, isEmpty);
  });

  test('explicit clear affects current account only', () async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    final key = await store.matrixDatabaseKey();
    await store.saveMatrixBinding(binding('@a:test', 'device-A'));
    await (store as dynamic).selectMatrixAccount(_home, '@b:test');
    await store.matrixDatabaseKey();
    await store.markMatrixClearPending();
    await store.clearMatrixIdentity();
    await (store as dynamic).selectMatrixAccount(_home, '@a:test');
    expect(await store.matrixClearPending(), isFalse);
    expect(await store.matrixDatabaseKey(), key);
    expect((await store.matrixBinding())?.matrixUserId, '@a:test');
  });

  test('failed pointer publication keeps old account and permits retry',
      () async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    final key = await store.matrixDatabaseKey();
    await store.saveMatrixBinding(binding('@a:test', 'device-A'));
    memory.beforeWrite = (name, _) async {
      if (name.contains('active_matrix_scope')) {
        throw StateError('disk unavailable');
      }
    };
    await expectLater((store as dynamic).selectMatrixAccount(_home, '@b:test'),
        throwsStateError);
    expect(await store.matrixDatabaseKey(), key);
    expect((await store.matrixBinding())?.matrixUserId, '@a:test');
    memory.beforeWrite = null;
    await (store as dynamic).selectMatrixAccount(_home, '@b:test');
    expect(await store.matrixDatabaseKey(), isNot(key));
  });
}
