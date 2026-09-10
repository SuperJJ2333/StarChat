import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/business_auth_contracts.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/core/session_bootstrap_controller.dart';
import 'package:liuhetong_mobile/session_gate.dart';
import 'session_bootstrap_controller_test.dart' show FakeMatrix;

final class _Memory implements SecureKeyValueStore {
  final data = <String, String>{};
  @override
  Future<void> delete(String key) async => data.remove(key);
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
}

http.Response _replaced() => http.Response(
    jsonEncode({
      'error': {'code': 'SESSION_REPLACED', 'message': '账号已在其他设备登录'}
    }),
    401,
    headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  testWidgets('replacement found before mounting still shows the reason',
      (tester) async {
    final store = SecureSessionStore(_Memory());
    await store.saveSession(
        accessToken: 'old', refreshToken: 'r', matrixUserId: '@alice:example');
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: store,
        client: MockClient((_) async => _replaced()));
    final bootstrap = SessionBootstrapController(
        business: api,
        matrix: FakeMatrix(isLoggedIn: true, userId: '@alice:example'));
    await bootstrap.bootstrap();
    await tester.pumpWidget(CupertinoApp(
        home: SessionGate(
            controller: bootstrap,
            unauthenticatedBuilder: (_) =>
                const CupertinoPageScaffold(child: Text('登录页面')),
            authenticatedBuilder: (_) =>
                const CupertinoPageScaffold(child: Text('聊天页面')))));
    await tester.pumpAndSettle();
    expect(find.text('账号已退出'), findsOneWidget);
    expect(find.textContaining('其他设备登录'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    bootstrap.dispose();
  });
  test(
      'startup replacement keeps the explicit reason instead of generic restore error',
      () async {
    final store = SecureSessionStore(_Memory());
    await store.saveSession(
        accessToken: 'old', refreshToken: 'r', matrixUserId: '@alice:example');
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: store,
        client: MockClient((_) async => _replaced()));
    final matrix = FakeMatrix(isLoggedIn: true, userId: '@alice:example');
    final bootstrap = SessionBootstrapController(business: api, matrix: matrix);
    await bootstrap.bootstrap();
    expect(bootstrap.state.status, SessionBootstrapStatus.unauthenticated);
    expect(bootstrap.state.message, contains('其他设备登录'));
    expect(matrix.clearCalls, 0);
    expect(matrix.suspendCalls, 1);
    bootstrap.dispose();
  });

  test('network failure during validity probe does not force logout', () async {
    final store = SecureSessionStore(_Memory());
    await store.saveSession(
        accessToken: 'old', refreshToken: 'r', matrixUserId: '@alice:example');
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: store,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/refresh')) {
            return http.Response(
                jsonEncode({'access_token': 'a', 'refresh_token': 'r'}), 200);
          }
          throw http.ClientException('offline');
        }));
    final matrix = FakeMatrix(isLoggedIn: true, userId: '@alice:example');
    final bootstrap = SessionBootstrapController(business: api, matrix: matrix);
    await bootstrap.bootstrap();
    await bootstrap.checkSessionValidity();
    expect(bootstrap.state.status, SessionBootstrapStatus.authenticated);
    expect(await store.session(), isNotNull);
    expect(matrix.suspendCalls, 0);
    expect(matrix.clearCalls, 0);
    bootstrap.dispose();
  });
  testWidgets('session gate explains forced logout on the login page',
      (tester) async {
    final store = SecureSessionStore(_Memory());
    await store.saveSession(
        accessToken: 'old', refreshToken: 'r', matrixUserId: '@alice:example');
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: store,
        client: MockClient((request) async => request.url.path
                .endsWith('/refresh')
            ? http.Response(
                jsonEncode({'access_token': 'a', 'refresh_token': 'r'}), 200)
            : _replaced()));
    final matrix = FakeMatrix(isLoggedIn: true, userId: '@alice:example');
    final bootstrap = SessionBootstrapController(business: api, matrix: matrix);
    await bootstrap.bootstrap();
    await tester.pumpWidget(CupertinoApp(
        home: SessionGate(
            controller: bootstrap,
            unauthenticatedBuilder: (_) =>
                const CupertinoPageScaffold(child: Text('登录页面')),
            authenticatedBuilder: (_) =>
                const CupertinoPageScaffold(child: Text('聊天页面')))));
    await bootstrap.checkSessionValidity();
    await tester.pumpAndSettle();
    expect(find.text('账号已退出'), findsOneWidget);
    expect(find.textContaining('本地聊天记录已保留'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('登录页面'), findsOneWidget);
    expect(matrix.clearCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    bootstrap.dispose();
  });
  test(
      'online replacement suspends Matrix, keeps history and exposes explicit reason',
      () async {
    final store = SecureSessionStore(_Memory());
    await store.saveSession(
        accessToken: 'old',
        refreshToken: 'old-r',
        matrixUserId: '@alice:example');
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: store,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/refresh')) {
            return http.Response(
                jsonEncode({'access_token': 'a', 'refresh_token': 'r'}), 200);
          }
          return _replaced();
        }));
    final matrix = FakeMatrix(isLoggedIn: true, userId: '@alice:example');
    final bootstrap = SessionBootstrapController(business: api, matrix: matrix);
    await bootstrap.bootstrap();
    expect(bootstrap.state.status, SessionBootstrapStatus.authenticated);
    await bootstrap.checkSessionValidity();
    expect(bootstrap.state.status, SessionBootstrapStatus.unauthenticated);
    expect(bootstrap.state.message, contains('其他设备登录'));
    expect(matrix.suspendCalls, 1);
    expect(matrix.clearCalls, 0);
    expect(bootstrap.canShowCachedMessages, isFalse);
    bootstrap.dispose();
  });
  test(
      'replaced current request emits once without refresh and clears only business',
      () async {
    final memory = _Memory();
    final store = SecureSessionStore(memory);
    await store.saveSession(accessToken: 'old', refreshToken: 'refresh');
    memory.data['local-encrypted-history'] = 'keep';
    var refreshes = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: store,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/refresh')) refreshes++;
          return _replaced();
        }));
    final events = <BusinessSessionInvalidation>[];
    final subscription = api.sessionInvalidations.listen(events.add);
    await expectLater(
        api.getJson('/profile/me'), throwsA(isA<BusinessApiException>()));
    expect(events.map((e) => e.code), ['SESSION_REPLACED']);
    expect(refreshes, 0);
    expect(await store.session(), isNull);
    expect(memory.data['local-encrypted-history'], 'keep');
    await subscription.cancel();
  });

  test(
      'late old replacement cannot clear or notify the newly logged in account',
      () async {
    final store = SecureSessionStore(_Memory());
    await store.saveSession(accessToken: 'old', refreshToken: 'old-r');
    final oldResponse = Completer<http.Response>();
    final requestStarted = Completer<void>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: store,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/login')) {
            return http.Response(
                jsonEncode({'access_token': 'new', 'refresh_token': 'new-r'}),
                200);
          }
          requestStarted.complete();
          return oldResponse.future;
        }));
    final events = <BusinessSessionInvalidation>[];
    final subscription = api.sessionInvalidations.listen(events.add);
    final oldRequest = api.getJson('/profile/me');
    final failure =
        expectLater(oldRequest, throwsA(isA<BusinessApiException>()));
    await requestStarted.future;
    await api.loginBusiness(
        username: 'new',
        password: 'password',
        deviceKey: 'phone',
        deviceName: 'Phone');
    oldResponse.complete(_replaced());
    await failure;
    expect((await store.session())?.accessToken, 'new');
    expect(events, isEmpty);
    await subscription.cancel();
  });

  test(
      'Matrix completion requires ACTIVE and sends credentials only in request body',
      () async {
    final store = SecureSessionStore(_Memory());
    await store.saveSession(accessToken: 'business', refreshToken: 'refresh');
    var status = 'PENDING';
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: store,
        client: MockClient((request) async {
          expect(request.url.path, '/api/v1/auth/matrix-session');
          expect(request.headers['Authorization'], 'Bearer business');
          expect(jsonDecode(request.body), {
            'matrix_access_token': 'matrix-memory',
            'matrix_device_id': 'DEVICE'
          });
          return http.Response(jsonEncode({'status': status}), 200);
        }));
    await expectLater(
        api.completeMatrixSession(
            matrixAccessToken: 'matrix-memory', matrixDeviceId: 'DEVICE'),
        throwsA(isA<BusinessApiException>()));
    status = 'ACTIVE';
    await api.completeMatrixSession(
        matrixAccessToken: 'matrix-memory', matrixDeviceId: 'DEVICE');
    expect((await store.session())?.accessToken, 'business');
  });
}
