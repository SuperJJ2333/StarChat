import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

void main() {
  test('queued session write rechecks page lifetime before saving', () async {
    final storage = GatedStore();
    final store = SecureSessionStore(storage);
    var current = true;
    final secondResponse = Completer<void>();
    var calls = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.invalid'),
        sessionStore: store,
        client: MockClient((request) async {
          calls++;
          if (calls == 2) secondResponse.complete();
          return http.Response(
              jsonEncode({
                'access_token': 'at$calls',
                'refresh_token': 'rt$calls',
                'matrix_user_id': '@user$calls:test'
              }),
              200);
        }));
    final first = api.phoneLogin(
        phone: '13800000001',
        code: '123456',
        deviceKey: 'first-device',
        deviceName: 'test');
    await storage.started.future;
    final second = api.phoneLogin(
        phone: '13900000001',
        code: '123456',
        deviceKey: 'second-device',
        deviceName: 'test',
        shouldContinue: () => current);
    final rejected = expectLater(second, throwsA(isA<BusinessApiException>()));
    await secondResponse.future;
    await Future<void>.delayed(Duration.zero);
    current = false;
    storage.release.complete();
    await first;
    await rejected;
    expect((await store.session())?.matrixUserId, '@user1:test');
  });
  for (final pending in [true, false]) {
    test(
        'leaving login rejects late ${pending ? "pending" : "active"} response',
        () async {
      var current = true;
      var calls = 0;
      final store = SecureSessionStore(MemoryStore());
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://example.invalid'),
          sessionStore: store,
          client: MockClient((request) async {
            calls++;
            current = false;
            return http.Response(
                jsonEncode(pending
                    ? {
                        'status': 'PENDING_MATRIX',
                        'login_ticket': 'opaque-ticket'
                      }
                    : {
                        'access_token': 'late',
                        'refresh_token': 'late',
                        'matrix_user_id': '@late:test'
                      }),
                pending ? 202 : 200);
          }));
      await expectLater(
          api.phoneLogin(
              phone: '13800000001',
              code: '123456',
              deviceKey: 'test-device',
              deviceName: 'test',
              shouldContinue: () => current),
          throwsA(isA<BusinessApiException>()));
      expect(calls, 1);
      expect(await store.session(), isNull);
    });
  }
  test('verified onboarding waits for Matrix before saving session', () async {
    final requests = <http.Request>[];
    final store = SecureSessionStore(MemoryStore());
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.invalid'),
        sessionStore: store,
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/complete')) {
            expect(await store.session(), isNull);
            expect(jsonDecode(request.body)['login_ticket'], 'opaque-ticket');
            return http.Response(
                jsonEncode({
                  'access_token': 'at',
                  'refresh_token': 'rt',
                  'matrix_user_id': '@new:test'
                }),
                200);
          }
          expect(jsonDecode(request.body)['invitation_code'], 'invite');
          expect(jsonDecode(request.body)['terms_accepted'], true);
          return http.Response(
              jsonEncode({
                'status': 'PENDING_MATRIX',
                'login_ticket': 'opaque-ticket',
                'retry_after_seconds': 2
              }),
              202);
        }));
    await api.phoneLogin(
        phone: '13800000001',
        code: '123456',
        deviceKey: 'test-device',
        deviceName: 'test',
        invitationCode: 'invite',
        termsAccepted: true);
    expect(requests.length, 2);
    expect((await store.session())?.matrixUserId, '@new:test');
  });
}

class MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class GatedStore extends MemoryStore {
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> write(String key, String value) async {
    if (key.contains('business_session') && !started.isCompleted) {
      started.complete();
      await release.future;
    }
    await super.write(key, value);
  }
}
