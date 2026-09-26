import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

class MemoryStore implements SecureKeyValueStore {
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

void main() {
  for (final replacement in ['none', 'manual', 'login']) {
    test(
        replacement == 'none'
            ? 'successful reset still ends its session after a trusted same-family refresh'
            : 'late reset after trusted refresh rejects $replacement session replacement',
        () async {
      final store = SecureSessionStore(MemoryStore());
      await store.saveSession(
          accessToken: 'old', refreshToken: 'old-r', matrixUserId: '@old:test');
      final resetResponse = Completer<http.Response>();
      final resetSent = Completer<void>();
      final requests = <http.Request>[];
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://api.test'),
          sessionStore: store,
          client: MockClient((request) async {
            requests.add(request);
            if (request.url.path.endsWith('/auth/refresh')) {
              return http.Response(
                  '{"access_token":"refreshed","refresh_token":"refreshed-r"}',
                  200);
            }
            if (request.url.path.endsWith('/auth/login')) {
              return http.Response(
                  '{"access_token":"new","refresh_token":"new-r","matrix_user_id":"@new:test"}',
                  200);
            }
            resetSent.complete();
            return resetResponse.future;
          }));
      final codes = <String>[];
      final subscription =
          api.sessionInvalidations.listen((event) => codes.add(event.code));
      addTearDown(subscription.cancel);
      final epoch = api.sessionEpoch;
      final reset = api.resetPassword(
          token: 'proof', newPassword: 'new-password-123', authenticated: true);
      await resetSent.future;
      await api.refreshSession();
      expect(api.sessionEpoch, epoch);
      expect((await store.session())!.accessToken, 'refreshed');
      if (replacement == 'manual') {
        await store.saveSession(
            accessToken: 'new',
            refreshToken: 'new-r',
            matrixUserId: '@old:test');
      } else if (replacement == 'login') {
        await api.login(
            username: 'new',
            password: 'new-password-123',
            deviceKey: 'new-device',
            deviceName: 'test');
      }
      resetResponse.complete(http.Response('', 204));
      if (replacement == 'none') {
        await reset;
        expect(codes, ['PASSWORD_CHANGED']);
        expect(await store.session(), isNull);
      } else {
        await expectLater(reset, throwsA(isA<BusinessApiException>()));
        expect(codes, isEmpty);
        expect((await store.session())!.accessToken, 'new');
      }
      expect(requests.where((request) => request.url.path.endsWith('/reset')),
          hasLength(1));
      expect(requests.first.headers['authorization'], 'Bearer old');
    });
  }
  testWidgets(
      'late reset success after the call deadline still invalidates its own session',
      (tester) async {
    final store = SecureSessionStore(MemoryStore());
    await store.saveSession(
        accessToken: 'old', refreshToken: 'r', matrixUserId: '@a:test');
    final response = Completer<http.Response>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: store,
        client: MockClient((r) => response.future));
    final codes = <String>[];
    final subscription =
        api.sessionInvalidations.listen((event) => codes.add(event.code));
    addTearDown(subscription.cancel);
    final reset = api.resetPassword(
        token: 'proof', newPassword: 'new-password-123', authenticated: true);
    final timedOut = expectLater(reset, throwsA(isA<TimeoutException>()));
    await tester.pump(const Duration(seconds: 9));
    await timedOut;
    response.complete(http.Response('', 204));
    await tester.pump();
    expect(codes, ['PASSWORD_CHANGED']);
    expect(await store.session(), isNull);
  });
  test('anonymous late reset cannot complete against a newly logged-in account',
      () async {
    final store = SecureSessionStore(MemoryStore());
    final response = Completer<http.Response>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: store,
        client: MockClient((r) => response.future));
    final reset = api.resetPassword(
        token: 'proof', newPassword: 'new-password-123', authenticated: false);
    await Future<void>.delayed(Duration.zero);
    await store.saveSession(
        accessToken: 'new', refreshToken: 'new-r', matrixUserId: '@new:test');
    response.complete(http.Response('', 204));
    await expectLater(reset, throwsA(isA<BusinessApiException>()));
    expect((await store.session())!.accessToken, 'new');
  });
  test(
      'password endpoint pins Bearer and never retries or downgrades after 401',
      () async {
    final store = SecureSessionStore(MemoryStore());
    await store.saveSession(
        accessToken: 'fixed-token',
        refreshToken: 'r',
        matrixUserId: '@alice:test');
    final requests = <http.Request>[];
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: store,
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
              '{"error":{"code":"AUTH_SESSION_ENDED","message":"登录已失效"}}', 401,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    await expectLater(
        api.requestPasswordCode(
            channel: 'email',
            target: 'bound@example.test',
            authenticated: true),
        throwsA(isA<BusinessApiException>()));
    expect(requests, hasLength(1));
    expect(requests.single.url.path, '/api/v1/auth/password/code/request');
    expect(requests.single.headers['authorization'], 'Bearer fixed-token');
  });
  test(
      'anonymous proof and 204 reset use frozen schema without session headers',
      () async {
    final requests = <http.Request>[];
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: SecureSessionStore(MemoryStore()),
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/verify')) {
            return http.Response(
                '{"reset_token":"proof","expires_in":300}', 200);
          }
          return http.Response('', 204);
        }));
    final proof = await api.verifyPasswordCode(
        channel: 'phone',
        target: '13800000001',
        code: '123456',
        authenticated: false);
    await api.resetPassword(
        token: proof, newPassword: 'new-password-123', authenticated: false);
    expect(
        requests.every((x) => !x.headers.containsKey('authorization')), isTrue);
    expect(jsonDecode(requests.last.body),
        {'token': 'proof', 'new_password': 'new-password-123'});
  });
  test('authenticated recovery without session never issues anonymous request',
      () async {
    var requests = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: SecureSessionStore(MemoryStore()),
        client: MockClient((request) async {
          requests++;
          return http.Response('{}', 202);
        }));
    await expectLater(
        api.requestPasswordCode(
            channel: 'email',
            target: 'bound@example.test',
            authenticated: true),
        throwsA(isA<BusinessApiException>()));
    expect(requests, 0);
  });
  test(
      'reset response after another session was stored preserves the new account',
      () async {
    final store = SecureSessionStore(MemoryStore());
    await store.saveSession(
        accessToken: 'old', refreshToken: 'old-r', matrixUserId: '@old:test');
    final response = Completer<http.Response>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: store,
        client: MockClient((r) => response.future));
    final events = <Object>[];
    final subscription = api.sessionInvalidations.listen(events.add);
    addTearDown(subscription.cancel);
    final reset = api.resetPassword(
        token: 'proof', newPassword: 'new-password-123', authenticated: true);
    await Future<void>.delayed(Duration.zero);
    await store.saveSession(
        accessToken: 'new', refreshToken: 'new-r', matrixUserId: '@new:test');
    response.complete(http.Response('', 204));
    await expectLater(reset, throwsA(isA<BusinessApiException>()));
    expect((await store.session())!.accessToken, 'new');
    expect(events, isEmpty);
  });
  test(
      'successful authenticated reset emits lifecycle event and only clears business session',
      () async {
    final backing = MemoryStore();
    final store = SecureSessionStore(backing);
    await store.saveSession(
        accessToken: 'old', refreshToken: 'r', matrixUserId: '@a:test');
    backing.values['matrix-history-marker'] = 'retained';
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: store,
        client: MockClient((r) async => http.Response('', 204)));
    final codes = <String>[];
    final subscription =
        api.sessionInvalidations.listen((event) => codes.add(event.code));
    addTearDown(subscription.cancel);
    await api.resetPassword(
        token: 'proof', newPassword: 'new-password-123', authenticated: true);
    expect(codes, ['PASSWORD_CHANGED']);
    expect(await store.session(), isNull);
    expect(backing.values['matrix-history-marker'], 'retained');
  });
}
