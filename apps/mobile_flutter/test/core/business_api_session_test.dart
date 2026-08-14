import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

final class MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override Future<void> delete(String key) async => values.remove(key);
  @override Future<String?> read(String key) async => values[key];
  @override Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  test('restore rotates and atomically replaces the stored token pair', () async {
    final storage = MemoryStore();
    final store = SecureSessionStore(storage);
    await store.saveSession(accessToken: 'old-a', refreshToken: 'old-r');
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: store,
      client: MockClient((request) async {
        expect(request.url.path, '/api/v1/auth/refresh');
        expect(jsonDecode(request.body)['refresh_token'], 'old-r');
        return http.Response(
          jsonEncode({'access_token': 'new-a', 'refresh_token': 'new-r'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    expect(await api.restoreSession(), BusinessSessionRestore.authenticated);
    expect((await store.session())?.accessToken, 'new-a');
    expect((await store.session())?.refreshToken, 'new-r');
  });

  test('network failure preserves tokens and reports offline', () async {
    final storage = MemoryStore();
    final store = SecureSessionStore(storage);
    await store.saveSession(accessToken: 'a', refreshToken: 'r');
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: store,
      client: MockClient((_) => throw http.ClientException('offline')),
    );

    expect(await api.restoreSession(), BusinessSessionRestore.offline);
    expect((await store.session())?.refreshToken, 'r');
  });

  test('authoritative refresh rejection clears the business session', () async {
    final storage = MemoryStore();
    final store = SecureSessionStore(storage);
    await store.saveSession(accessToken: 'a', refreshToken: 'revoked');
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: store,
      client: MockClient((_) async => http.Response(
        jsonEncode({'error': {'code': 'REFRESH_TOKEN_INVALID', 'message': 'invalid'}}),
        401,
      )),
    );

    expect(await api.restoreSession(), BusinessSessionRestore.invalid);
    expect(await store.session(), isNull);
  });

  test('logout revokes the refresh token before local cleanup', () async {
    final storage = MemoryStore();
    final store = SecureSessionStore(storage);
    await store.saveSession(accessToken: 'a', refreshToken: 'r');
    var revoked = false;
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: store,
      client: MockClient((request) async {
        revoked = jsonDecode(request.body)['refresh_token'] == 'r';
        return http.Response('', 204);
      }),
    );

    await api.logout();

    expect(revoked, isTrue);
    expect(await store.session(), isNull);
  });

  test('authenticated request refreshes once and replays with new access token', () async {
    final storage = MemoryStore();
    final store = SecureSessionStore(storage);
    await store.saveSession(accessToken: 'expired-a', refreshToken: 'valid-r');
    var balanceCalls = 0;
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: store,
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/auth/refresh') {
          return http.Response(
            jsonEncode({'access_token': 'new-a', 'refresh_token': 'new-r'}),
            200,
          );
        }
        balanceCalls++;
        if (balanceCalls == 1) return http.Response('{}', 401);
        expect(request.headers['Authorization'], 'Bearer new-a');
        return http.Response(jsonEncode({'balance': '0.00'}), 200);
      }),
    );

    expect((await api.caibiBalance())['balance'], '0.00');
    expect(balanceCalls, 2);
  });
}
