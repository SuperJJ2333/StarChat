import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
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
}
