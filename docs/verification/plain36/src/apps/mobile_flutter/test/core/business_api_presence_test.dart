import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  test('presence heartbeat requires a business session before dispatch',
      () async {
    var requests = 0;
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: SecureSessionStore(_MemoryStore()),
      client: MockClient((_) async {
        requests++;
        return http.Response('', 204);
      }),
    );

    await expectLater(
      api.sendPresenceHeartbeat(clientVersion: 'flutter-1'),
      throwsA(isA<BusinessApiException>()),
    );
    expect(requests, 0);
  });

  test('presence heartbeat posts only version metadata with bearer auth',
      () async {
    final store = SecureSessionStore(_MemoryStore());
    await store.saveSession(
      accessToken: 'access-token',
      refreshToken: 'r',
      deviceKey: 'device-1',
    );
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: store,
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/presence/heartbeat');
        expect(request.headers['authorization'], 'Bearer access-token');
        expect(request.headers['x-device-key'], 'device-1');
        expect(jsonDecode(request.body), {'client_version': 'flutter-1'});
        return http.Response('', 204);
      }),
    );

    await api.sendPresenceHeartbeat(clientVersion: 'flutter-1');
  });
}
