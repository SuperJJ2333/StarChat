import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

final class _Store implements SecureKeyValueStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

Future<SecureSessionStore> _session() async {
  final store = SecureSessionStore(_Store());
  await store.saveSession(
    accessToken: 'test-access',
    refreshToken: 'test-refresh',
    matrixUserId: '@a:example.test',
  );
  return store;
}

void main() {
  test('media PUT timeout scales by 64 KiB and caps at 360 seconds', () {
    expect(momentMediaPutTimeout(512 * 1024), const Duration(seconds: 30));
    expect(
        momentMediaPutTimeout(20 * 1024 * 1024), const Duration(seconds: 335));
    expect(momentMediaPutTimeout(20 * 1024 * 1024 + 1),
        const Duration(seconds: 336));
    expect(
        momentMediaPutTimeout(40 * 1024 * 1024), const Duration(seconds: 360));
  });

  test('slow valid video PUT uses a media budget; ordinary GET stays short',
      () async {
    final client = MockClient((request) async {
      await Future<void>.delayed(const Duration(seconds: 9));
      return request.method == 'PUT'
          ? http.Response('', 204)
          : http.Response('{}', 200);
    });
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: await _session(),
      client: client,
    );
    final lease = await api.captureMomentPublishSession();

    await api.putMomentTask(
      lease,
      'upload-1',
      Uint8List(64 * 1024),
      'video/mp4',
    );
    await expectLater(
        api.getJson('/profile'), throwsA(isA<TimeoutException>()));
  });

  test('20 MiB media PUT survives a 9-second local transfer', () async {
    var puts = 0;
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: await _session(),
      client: MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.url.path,
            '/api/v1/moments/media/uploads/upload-20m/content');
        expect(request.bodyBytes.length, 20 * 1024 * 1024);
        puts++;
        await Future<void>.delayed(const Duration(seconds: 9));
        return http.Response('', 204);
      }),
    );
    final lease = await api.captureMomentPublishSession();

    await api.putMomentTask(
      lease,
      'upload-20m',
      Uint8List(20 * 1024 * 1024),
      'video/mp4',
    );
    expect(puts, 1);
  });

  test('media PUT 401 refresh has time for two media attempts', () async {
    final store = await _session();
    var puts = 0;
    var refreshes = 0;
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: store,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth/refresh')) {
          refreshes++;
          return http.Response(
            jsonEncode({
              'access_token': 'renewed-access',
              'refresh_token': 'renewed-refresh',
            }),
            200,
          );
        }
        expect(request.method, 'PUT');
        expect(
            request.url.path, '/api/v1/moments/media/uploads/upload-1/content');
        puts++;
        if (puts == 1) {
          expect(request.headers['Authorization'], 'Bearer test-access');
          await Future<void>.delayed(const Duration(seconds: 9));
          return http.Response('{}', 401);
        }
        expect(request.headers['Authorization'], 'Bearer renewed-access');
        await Future<void>.delayed(const Duration(seconds: 12));
        return http.Response('', 204);
      }),
    );
    final lease = await api.captureMomentPublishSession();

    await api.putMomentTask(
      lease,
      'upload-1',
      Uint8List(512 * 1024),
      'video/mp4',
    );
    expect(puts, 2);
    expect(refreshes, 1);
  });

  test('media PUT does not retry after account switch', () async {
    final store = await _session();
    var puts = 0;
    var refreshes = 0;
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: store,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth/refresh')) {
          refreshes++;
          return http.Response('{}', 200);
        }
        puts++;
        await store.saveSession(
          accessToken: 'other-access',
          refreshToken: 'other-refresh',
          matrixUserId: '@b:example.test',
        );
        return http.Response('{}', 401);
      }),
    );
    final lease = await api.captureMomentPublishSession();

    await expectLater(
      api.putMomentTask(lease, 'upload-1', Uint8List(1), 'image/jpeg'),
      throwsA(isA<BusinessApiException>()),
    );
    expect(puts, 1);
    expect(refreshes, 0);
  });
}
