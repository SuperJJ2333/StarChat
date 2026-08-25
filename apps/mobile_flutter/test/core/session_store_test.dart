import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

final class MemorySecureKeyValueStore implements SecureKeyValueStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  test('stores the business token pair as one versioned record', () async {
    final storage = MemorySecureKeyValueStore();
    final store = SecureSessionStore(storage);

    await store.saveSession(accessToken: 'a1', refreshToken: 'r1');

    expect(
      await store.session(),
      const StoredBusinessSession(
        version: 1,
        accessToken: 'a1',
        refreshToken: 'r1',
      ),
    );
    expect(storage.values.keys, contains('liuhetong.business_session.v1'));
    expect(storage.values.keys, isNot(contains('liuhetong.access_token')));
  });

  test('migrates a complete legacy token pair exactly once', () async {
    final storage = MemorySecureKeyValueStore()
      ..values['liuhetong.access_token'] = 'legacy-a'
      ..values['liuhetong.refresh_token'] = 'legacy-r';
    final store = SecureSessionStore(storage);

    final session = await store.session();

    expect(session?.accessToken, 'legacy-a');
    expect(session?.refreshToken, 'legacy-r');
    expect(storage.values['liuhetong.access_token'], isNull);
    expect(storage.values['liuhetong.refresh_token'], isNull);
  });

  test('rejects and clears an incomplete legacy token pair', () async {
    final storage = MemorySecureKeyValueStore()
      ..values['liuhetong.access_token'] = 'orphan';
    final store = SecureSessionStore(storage);

    expect(await store.session(), isNull);
    expect(storage.values['liuhetong.access_token'], isNull);
  });

  test('business logout preserves the stable matrix database key', () async {
    final storage = MemorySecureKeyValueStore();
    final store = SecureSessionStore(storage);
    await store.saveSession(accessToken: 'a', refreshToken: 'r');
    final firstKey = await store.matrixDatabaseKey();

    await store.clearBusinessSession();

    expect(await store.session(), isNull);
    expect(await store.matrixDatabaseKey(), firstKey);
    expect(base64Url.decode(base64Url.normalize(firstKey)), hasLength(32));
  });

  test('business logout preserves the independent matrix identity', () async {
    final storage = MemorySecureKeyValueStore();
    final store = SecureSessionStore(storage);
    final binding = MatrixLocalBinding(
      version: 1,
      matrixUserId: '@alice:matrix.localhost',
      deviceId: 'ALICEDEVICE',
      homeserver: 'https://matrix.example',
      databaseGeneration: 'generation-1',
    );
    await store.saveSession(accessToken: 'access', refreshToken: 'refresh');
    await store.saveMatrixBinding(binding);
    final databaseKey = await store.matrixDatabaseKey();
    await store.saveEncryptedRecoveryKey('fake-encrypted-recovery-key');
    final salt = await store.diagnosticSalt();

    await store.clearBusinessSession();

    expect(await store.session(), isNull);
    expect(await store.matrixBinding(), binding);
    expect(await store.matrixDatabaseKey(), databaseKey);
    expect(
      await store.encryptedRecoveryKey(),
      'fake-encrypted-recovery-key',
    );
    expect(await store.diagnosticSalt(), salt);
    expect(base64Url.decode(base64Url.normalize(salt)), hasLength(32));
  });

  test('clearMatrixIdentity deletes matrix material without recreating it',
      () async {
    final storage = MemorySecureKeyValueStore();
    final store = SecureSessionStore(storage);
    await store.saveSession(accessToken: 'access', refreshToken: 'refresh');
    await store.saveMatrixBinding(
      MatrixLocalBinding(
        version: 1,
        matrixUserId: '@alice:matrix.localhost',
        deviceId: 'ALICEDEVICE',
        homeserver: 'https://matrix.example',
        databaseGeneration: 'generation-1',
      ),
    );
    await store.matrixDatabaseKey();
    await store.saveEncryptedRecoveryKey('fake-encrypted-recovery-key');
    await store.diagnosticSalt();
    final registrationDeviceKey = await store.registrationDeviceKey();

    await store.clearMatrixIdentity();

    expect(await store.matrixBinding(), isNull);
    expect(
      storage.values.keys,
      isNot(containsAll(<String>{
        'liuhetong.matrix_local_binding.v1',
        'liuhetong.matrix_database_key.v1',
        'liuhetong.encrypted_recovery_key',
        'liuhetong.diagnostic_salt.v1',
      })),
    );
    expect(
        storage.values, isNot(contains('liuhetong.matrix_local_binding.v1')));
    expect(storage.values, isNot(contains('liuhetong.matrix_database_key.v1')));
    expect(storage.values, isNot(contains('liuhetong.encrypted_recovery_key')));
    expect(storage.values, isNot(contains('liuhetong.diagnostic_salt.v1')));
    expect(await store.session(), isNotNull);
    expect(await store.registrationDeviceKey(), registrationDeviceKey);

    final regeneratedDatabaseKey = await store.matrixDatabaseKey();
    final regeneratedSalt = await store.diagnosticSalt();
    expect(regeneratedDatabaseKey, isNotEmpty);
    expect(regeneratedSalt, isNotEmpty);
    expect(storage.values, contains('liuhetong.matrix_database_key.v1'));
    expect(storage.values, contains('liuhetong.diagnostic_salt.v1'));
  });

  test('matrix binding rejects malformed JSON', () async {
    final storage = MemorySecureKeyValueStore()
      ..values['liuhetong.matrix_local_binding.v1'] = '{not-json';
    final store = SecureSessionStore(storage);

    expect(store.matrixBinding(), throwsFormatException);
  });

  test('matrix binding rejects an unsupported version', () async {
    final storage = MemorySecureKeyValueStore()
      ..values['liuhetong.matrix_local_binding.v1'] = jsonEncode({
        'version': 2,
        'matrix_user_id': '@alice:matrix.localhost',
        'device_id': 'ALICEDEVICE',
        'homeserver': 'https://matrix.example',
        'database_generation': 'generation-1',
      });
    final store = SecureSessionStore(storage);

    expect(store.matrixBinding(), throwsFormatException);
  });
}
