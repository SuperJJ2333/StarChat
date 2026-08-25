import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

final class MemorySecureKeyValueStore implements SecureKeyValueStore {
  final values = <String, String>{};
  final attemptedDeletes = <String>[];
  final deleteErrors = <String, Object>{};
  Future<void> Function(String key)? beforeRead;
  Future<void> Function(String key, String value)? beforeWrite;

  @override
  Future<void> delete(String key) async {
    attemptedDeletes.add(key);
    final error = deleteErrors[key];
    if (error != null) throw error;
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    await beforeRead?.call(key);
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    await beforeWrite?.call(key, value);
    values[key] = value;
  }
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
    storage.values['liuhetong.access_token'] = 'legacy-access';
    storage.values['liuhetong.refresh_token'] = 'legacy-refresh';
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
    expect(storage.values['liuhetong.access_token'], 'legacy-access');
    expect(storage.values['liuhetong.refresh_token'], 'legacy-refresh');

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

  test('concurrent diagnostic salt reads share one generated value', () async {
    const saltKey = 'liuhetong.diagnostic_salt.v1';
    final storage = MemorySecureKeyValueStore();
    final firstReadStarted = Completer<void>();
    final releaseFirstRead = Completer<void>();
    var saltReads = 0;
    var saltWrites = 0;
    storage.beforeRead = (key) async {
      if (key != saltKey) return;
      saltReads += 1;
      if (saltReads == 1) {
        firstReadStarted.complete();
        await releaseFirstRead.future;
      }
    };
    storage.beforeWrite = (key, _) async {
      if (key == saltKey) saltWrites += 1;
    };
    final store = SecureSessionStore(storage);

    final first = store.diagnosticSalt();
    await firstReadStarted.future;
    final second = store.diagnosticSalt();
    await Future<void>.delayed(Duration.zero);

    expect(saltReads, 1);
    releaseFirstRead.complete();
    final salts = await Future.wait([first, second]);
    expect(salts.toSet(), hasLength(1));
    expect(saltWrites, 1);
  });

  test('clear waits for an in-flight matrix binding save', () async {
    const bindingKey = 'liuhetong.matrix_local_binding.v1';
    final storage = MemorySecureKeyValueStore();
    final saveStarted = Completer<void>();
    final releaseSave = Completer<void>();
    storage.beforeWrite = (key, _) async {
      if (key == bindingKey) {
        saveStarted.complete();
        await releaseSave.future;
      }
    };
    final store = SecureSessionStore(storage);
    final save = store.saveMatrixBinding(
      MatrixLocalBinding(
        version: 1,
        matrixUserId: '@alice:matrix.localhost',
        deviceId: 'ALICEDEVICE',
        homeserver: 'https://matrix.example',
        databaseGeneration: 'generation-1',
      ),
    );
    await saveStarted.future;
    var clearCompleted = false;
    final clear = store.clearMatrixIdentity().whenComplete(() {
      clearCompleted = true;
    });

    await Future<void>.delayed(Duration.zero);
    expect(clearCompleted, isFalse);
    releaseSave.complete();
    await Future.wait([save, clear]);

    expect(storage.values, isNot(contains(bindingKey)));
  });

  test('clear attempts every matrix delete and preserves other domains',
      () async {
    const matrixKeysInDeleteOrder = <String>[
      'liuhetong.encrypted_recovery_key',
      'liuhetong.matrix_database_key.v1',
      'liuhetong.diagnostic_salt.v1',
      'liuhetong.matrix_local_binding.v1',
    ];
    for (final failingKey in matrixKeysInDeleteOrder) {
      final storage = MemorySecureKeyValueStore()
        ..values.addAll({
          for (final key in matrixKeysInDeleteOrder) key: 'fake-value',
          'liuhetong.business_session.v1': 'fake-business-session',
          'liuhetong.registration_device_key.v1': 'fake-device-key',
          'liuhetong.access_token': 'legacy-access',
          'liuhetong.refresh_token': 'legacy-refresh',
        })
        ..deleteErrors[failingKey] = StateError('delete failed: $failingKey');
      final store = SecureSessionStore(storage);

      await expectLater(
        store.clearMatrixIdentity(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'delete failed: $failingKey',
          ),
        ),
      );

      expect(storage.attemptedDeletes, matrixKeysInDeleteOrder);
      for (final key in matrixKeysInDeleteOrder) {
        expect(storage.values.containsKey(key), key == failingKey);
      }
      expect(
        storage.values['liuhetong.business_session.v1'],
        'fake-business-session',
      );
      expect(
        storage.values['liuhetong.registration_device_key.v1'],
        'fake-device-key',
      );
      expect(storage.values['liuhetong.access_token'], 'legacy-access');
      expect(storage.values['liuhetong.refresh_token'], 'legacy-refresh');
    }
  });

  test('diagnostic salt rejects invalid persisted values without replacing',
      () async {
    const saltKey = 'liuhetong.diagnostic_salt.v1';
    final invalidValues = <String>[
      'not+base64url',
      base64UrlEncode(List<int>.filled(31, 1)),
    ];
    for (final invalidValue in invalidValues) {
      final storage = MemorySecureKeyValueStore()
        ..values[saltKey] = invalidValue;
      final store = SecureSessionStore(storage);

      await expectLater(store.diagnosticSalt(), throwsFormatException);
      expect(storage.values[saltKey], invalidValue);
    }
  });

  test('matrix binding rejects non-string fields', () async {
    final storage = MemorySecureKeyValueStore()
      ..values['liuhetong.matrix_local_binding.v1'] = jsonEncode({
        'version': 1,
        'matrix_user_id': '@alice:matrix.localhost',
        'device_id': 123,
        'homeserver': 'https://matrix.example',
        'database_generation': 'generation-1',
      });
    final store = SecureSessionStore(storage);

    expect(store.matrixBinding(), throwsFormatException);
  });

  test('matrix binding rejects empty or padded opaque fields', () {
    final invalidBindings = <MatrixLocalBinding Function()>[
      () => MatrixLocalBinding(
            version: 1,
            matrixUserId: '',
            deviceId: 'ALICEDEVICE',
            homeserver: 'https://matrix.example',
            databaseGeneration: 'generation-1',
          ),
      () => MatrixLocalBinding(
            version: 1,
            matrixUserId: ' @alice:matrix.localhost ',
            deviceId: 'ALICEDEVICE',
            homeserver: 'https://matrix.example',
            databaseGeneration: 'generation-1',
          ),
      () => MatrixLocalBinding(
            version: 1,
            matrixUserId: '@alice:matrix.localhost',
            deviceId: ' ALICEDEVICE ',
            homeserver: 'https://matrix.example',
            databaseGeneration: 'generation-1',
          ),
      () => MatrixLocalBinding(
            version: 1,
            matrixUserId: '@alice:matrix.localhost',
            deviceId: 'ALICEDEVICE',
            homeserver: ' https://matrix.example ',
            databaseGeneration: 'generation-1',
          ),
      () => MatrixLocalBinding(
            version: 1,
            matrixUserId: '@alice:matrix.localhost',
            deviceId: 'ALICEDEVICE',
            homeserver: 'https://matrix.example',
            databaseGeneration: ' generation-1 ',
          ),
    ];
    for (final createBinding in invalidBindings) {
      expect(
        createBinding,
        throwsFormatException,
      );
    }
  });
}
