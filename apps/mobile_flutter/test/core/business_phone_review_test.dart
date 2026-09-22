import 'dart:async';
import 'dart:convert';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'business_phone_client_test.dart' show MemoryStore;

http.Response response(Map<String, dynamic> body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});
Map<String, dynamic> tokens(String who) => {
      'access_token': '$who-at',
      'refresh_token': '$who-rt',
      'matrix_user_id': '@$who:test'
    };
Future<Map<String, dynamic>> login(BusinessApiClient api) => api.phoneLogin(
    phone: '+8613800000001',
    code: '123456',
    deviceKey: 'device-123',
    deviceName: 'test');

void main() {
  test('phone login clears old Matrix cooldown and persists actual session',
      () async {
    final store = SecureSessionStore(MemoryStore());
    await store.saveSession(
        accessToken: 'old-at',
        refreshToken: 'old-rt',
        matrixUserId: '@old:test');
    var grants = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: store,
        client: MockClient((r) async {
          if (r.url.path.endsWith('/auth/phone/login')) {
            return response(tokens('new'));
          }
          if (r.url.path.endsWith('/matrix-login-token')) {
            grants++;
            if (grants == 1) {
              return response({
                'error': {
                  'code': 'MATRIX_LOGIN_RATE_LIMITED',
                  'message': 'retry'
                }
              }, 429);
            }
            expect(r.headers['Authorization'], 'Bearer new-at');
            return response({
              'login_token': 'grant',
              'homeserver': 'https://matrix.test',
              'expires_in': 60,
              'matrix_user_id': '@new:test'
            });
          }
          throw StateError('Unexpected route');
        }));
    await expectLater(
        api.issueMatrixLoginToken(), throwsA(isA<BusinessApiException>()));
    await login(api);
    final stored = await store.session();
    expect(stored!.accessToken, 'new-at');
    expect(stored.refreshToken, 'new-rt');
    expect(stored.deviceKey, 'device-123');
    expect(stored.matrixUserId, '@new:test');
    expect((await api.issueMatrixLoginToken()).matrixUserId, '@new:test');
    expect(grants, 2);
  });
  test('late phone login cannot restore logged-out session', () async {
    final store = SecureSessionStore(MemoryStore());
    final pendingResponse = Completer<http.Response>();
    final started = Completer<void>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: store,
        client: MockClient((r) async {
          if (r.url.path.endsWith('/auth/phone/login')) {
            started.complete();
            return pendingResponse.future;
          }
          return response({});
        }));
    final assertion =
        expectLater(login(api), throwsA(isA<BusinessApiException>()));
    await started.future;
    await api.logout();
    pendingResponse.complete(response(tokens('late')));
    await assertion;
    expect(await store.session(), isNull);
  });
  test('wrong OTP preserves stored session', () async {
    final store = SecureSessionStore(MemoryStore());
    await store.saveSession(
        accessToken: 'old-at',
        refreshToken: 'old-rt',
        matrixUserId: '@old:test');
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: store,
        client: MockClient((r) async => response({
              'error': {'code': 'OTP_INVALID', 'message': 'invalid'}
            }, 400)));
    await expectLater(
        login(api),
        throwsA(isA<BusinessApiException>()
            .having((e) => e.code, 'code', 'OTP_INVALID')));
    expect((await store.session())!.accessToken, 'old-at');
  });
  final operations = <String, Future<dynamic> Function(BusinessApiClient)>{
    'register': (api) => api.registerWithPhone(
        username: 'alice',
        phone: '+8613800000001',
        password: 'correct horse battery staple',
        invitationCode: 'INV'),
    'registration request': (api) => api.requestRegistrationOtp('r' * 40),
    'registration verify': (api) => api.verifyRegistrationPhone(
        registrationSession: 'r' * 40, phone: '+8613800000001', code: '123456'),
    'login request': (api) => api.requestPhoneLoginOtp('+8613800000001'),
    'login': login,
  };
  for (final entry in operations.entries) {
    test('${entry.key} has bounded wait and ignores late result', () {
      fakeAsync((clock) {
        final store = SecureSessionStore(MemoryStore());
        final pending = Completer<http.Response>();
        Object? failure;
        var finished = false;
        final api = BusinessApiClient(
            baseUri: Uri.parse('https://api.test'),
            sessionStore: store,
            client: MockClient((r) => pending.future));
        entry.value(api).then<void>((_) {
          finished = true;
        }, onError: (Object e) {
          failure = e;
          finished = true;
        });
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 9));
        clock.flushMicrotasks();
        expect(finished, isTrue);
        expect(failure, isA<TimeoutException>());
        pending.complete(response(tokens('late')));
        clock.flushMicrotasks();
        StoredBusinessSession? saved;
        store.session().then((s) => saved = s);
        clock.flushMicrotasks();
        expect(saved, isNull);
      });
    });
  }
}
