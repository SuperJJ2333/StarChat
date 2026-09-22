import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/core/session_bootstrap_controller.dart';
import 'session_bootstrap_controller_test.dart' show FakeMatrix;

class FaultStore implements SecureKeyValueStore {
  final data = <String, String>{};
  bool failPending = false;
  bool failResult = false;
  bool commitBeforeFailure = false;
  bool failRead = false;
  @override
  Future<String?> read(String key) async {
    if (failRead) throw PlatformException(code: 'locked');
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    final session = key == 'liuhetong.business_session.v1';
    final content = session ? jsonDecode(value) as Map : const {};
    final fail = session &&
        ((failPending && content['pending_refresh_operation'] != null) ||
            (failResult && content['refresh_token'] == 'next-refresh'));
    if (!fail || commitBeforeFailure) data[key] = value;
    if (fail) throw PlatformException(code: 'write_failed');
  }

  @override
  Future<void> delete(String key) async => data.remove(key);
}

http.Response nextPair() => http.Response(
    jsonEncode({
      'access_token': 'next-access',
      'refresh_token': 'next-refresh',
    }),
    200);

Future<SecureSessionStore> seed(FaultStore memory) async {
  final store = SecureSessionStore(memory);
  await store.saveSession(
      accessToken: 'old-access',
      refreshToken: 'old-refresh',
      matrixUserId: '@alice:example',
      deviceKey: 'installation');
  return store;
}

BusinessApiClient apiFor(SecureSessionStore store,
        Future<http.Response> Function(http.Request) handler) =>
    BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: store,
        client: MockClient(handler));

void main() {
  test(
      'slow 401 and shared recovery respect total caller budget without losing pending',
      () async {
    final memory = FaultStore();
    final store = await seed(memory);
    var refreshCalls = 0;
    final recovered = Completer<void>();
    final api = apiFor(store, (request) async {
      await Future<void>.delayed(const Duration(seconds: 7));
      if (request.url.path.endsWith('/auth/refresh')) {
        refreshCalls++;
        if (refreshCalls == 1) throw http.ClientException('lost');
        recovered.complete();
        return nextPair();
      }
      return http.Response('{"error":{"code":"TOKEN_INVALID"}}', 401);
    });
    final watch = Stopwatch()..start();
    await expectLater(api.getJson('/probe'), throwsA(isA<TimeoutException>()));
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 20750)));
    expect((await store.session())!.refreshToken, 'old-refresh');
    await recovered.future;
    // The independent shared refresh owns its result even after this caller times out.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect((await store.session())!.refreshToken, 'next-refresh');
  }, timeout: const Timeout(Duration(seconds: 35)));
  test(
      'pending operation survives Matrix identity binding without losing device key',
      () async {
    final memory = FaultStore();
    final store = await seed(memory);
    memory.failResult = true;
    final api = apiFor(store, (_) async => nextPair());
    await api.restoreSession();
    final before =
        jsonDecode(memory.data['liuhetong.business_session.v1']!) as Map;
    await api.bindMatrixUserId('@alice:example');
    final after =
        jsonDecode(memory.data['liuhetong.business_session.v1']!) as Map;
    expect(after['device_key'], before['device_key']);
    expect(after['pending_refresh_operation'],
        before['pending_refresh_operation']);
  });

  test(
      'replay and replacement show true cause without asserting another device',
      () async {
    for (final code in ['REFRESH_TOKEN_REUSED', 'SESSION_REPLACED']) {
      final memory = FaultStore();
      final store = await seed(memory);
      final api = apiFor(
          store,
          (_) async => http.Response(
              jsonEncode({
                'error': {'code': code, 'message': 'server'}
              }),
              401));
      final controller = SessionBootstrapController(
          business: api,
          matrix: FakeMatrix(isLoggedIn: true, userId: '@alice:example'));
      await controller.bootstrap();
      expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
      expect(controller.state.message, isNot(contains('其他设备')));
      expect(controller.state.message,
          contains(code == 'REFRESH_TOKEN_REUSED' ? '登录凭证校验异常' : '账号已重新登录'));
      controller.dispose();
    }
  });

  test(
      'background return may resume one round but repeated callers obey cooldown',
      () async {
    final memory = FaultStore();
    final store = await seed(memory);
    var calls = 0;
    final api = apiFor(store, (_) async {
      calls++;
      throw http.ClientException('offline');
    });
    await api.restoreSession();
    expect(calls, 2);
    await api.restoreSession();
    expect(calls, 2);
    api.setSessionForeground(false);
    api.setSessionForeground(true);
    await api.restoreSession();
    expect(calls, 4);
  });

  test(
      'superseded response rereads newer durable credentials without clearing them',
      () async {
    final memory = FaultStore();
    final store = await seed(memory);
    final api = apiFor(store, (_) async {
      await store.saveSession(
          accessToken: 'newest-access',
          refreshToken: 'newest-refresh',
          matrixUserId: '@alice:example',
          deviceKey: 'installation');
      return http.Response(
          '{"error":{"code":"REFRESH_RESULT_SUPERSEDED"}}', 409);
    });
    expect((await api.refreshSession()).refreshToken, 'newest-refresh');
    expect((await store.session())!.refreshToken, 'newest-refresh');
  });

  test('late refresh response cannot restore explicit logout', () async {
    final memory = FaultStore();
    final store = await seed(memory);
    final started = Completer<void>();
    final reply = Completer<http.Response>();
    final api = apiFor(store, (_) {
      started.complete();
      return reply.future;
    });
    final pending = api.refreshSession();
    final rejected = expectLater(pending, throwsA(isA<BusinessApiException>()));
    await started.future;
    await api.clearLocalSession();
    reply.complete(nextPair());
    await rejected;
    expect(await store.session(), isNull);
  });
  test(
      'server commits then response is lost: retry same durable operation, no logout',
      () async {
    final memory = FaultStore();
    final store = await seed(memory);
    final requests = <Map>[];
    final api = apiFor(store, (request) async {
      final body = jsonDecode(request.body) as Map;
      requests.add(body);
      final durable =
          jsonDecode(memory.data['liuhetong.business_session.v1']!) as Map;
      expect(body['operation_id'], isNotNull);
      expect(body['operation_id'], durable['pending_refresh_operation']);
      if (requests.length == 1) {
        throw http.ClientException('response lost after commit');
      }
      expect(body, requests.first);
      return nextPair();
    });
    var invalidations = 0;
    final subscription =
        api.sessionInvalidations.listen((_) => invalidations++);
    expect((await api.refreshSession()).refreshToken, 'next-refresh');
    expect(requests, hasLength(2));
    expect(invalidations, 0);
    expect(
        jsonDecode(memory.data['liuhetong.business_session.v1']!)[
            'pending_refresh_operation'],
        isNull);
    await subscription.cancel();
  });

  test('prewrite failure never sends request and never deletes session',
      () async {
    final memory = FaultStore();
    final store = await seed(memory);
    memory.failPending = true;
    var requests = 0;
    final api = apiFor(store, (_) async {
      requests++;
      return nextPair();
    });
    expect(await api.restoreSession(), BusinessSessionRestore.offline);
    expect(requests, 0);
    expect((await store.session())!.refreshToken, 'old-refresh');
  });

  for (final pending in [true, false]) {
    test(
        'write committed but exception returned: reread ${pending ? "pending" : "result"}',
        () async {
      final memory = FaultStore();
      final store = await seed(memory);
      memory.commitBeforeFailure = true;
      memory.failPending = pending;
      memory.failResult = !pending;
      var requests = 0;
      final api = apiFor(store, (_) async {
        requests++;
        return nextPair();
      });
      expect((await api.refreshSession()).refreshToken, 'next-refresh');
      expect((await store.session())!.refreshToken, 'next-refresh');
      expect(requests, 1);
    });
  }

  test(
      'result not persisted survives API/store reconstruction with same operation',
      () async {
    final memory = FaultStore();
    final store = await seed(memory);
    memory.failResult = true;
    final bodies = <Map>[];
    Future<http.Response> server(http.Request request) async {
      bodies.add(jsonDecode(request.body) as Map);
      return nextPair();
    }

    final first = apiFor(store, server);
    expect(await first.restoreSession(), BusinessSessionRestore.offline);
    expect((await store.session())!.refreshToken, 'old-refresh');
    memory.failResult = false;
    final fresh = apiFor(SecureSessionStore(memory), server);
    expect((await fresh.refreshSession()).refreshToken, 'next-refresh');
    expect(bodies.length, greaterThanOrEqualTo(2));
    expect(
        bodies.every(
            (body) => body['operation_id'] == bodies.first['operation_id']),
        isTrue);
    expect(bodies.first['operation_id'], isNotNull);
  });

  test(
      'temporary read unavailability remains offline without deleting credentials',
      () async {
    final memory = FaultStore();
    final store = await seed(memory);
    memory.failRead = true;
    final api = apiFor(store, (_) async => nextPair());
    expect(await api.restoreSession(), BusinessSessionRestore.offline);
    memory.failRead = false;
    expect((await store.session())!.refreshToken, 'old-refresh');
  });

  for (final response in [
    http.Response('proxy unauthorized', 401),
    http.Response('{"error":{"code":"UNKNOWN_FAILURE"}}', 401),
    http.Response('{"error":{"code":"VALIDATION_ERROR"}}', 422)
  ]) {
    test('untrusted/nonterminal ${response.statusCode} never clears login',
        () async {
      final memory = FaultStore();
      final store = await seed(memory);
      final api = apiFor(store, (_) async => response);
      expect(await api.restoreSession(), BusinessSessionRestore.offline);
      expect(await store.session(), isNotNull);
    });
  }

  test('real refresh replay rejection still terminates session', () async {
    final memory = FaultStore();
    final store = await seed(memory);
    final api = apiFor(
        store,
        (_) async => http.Response(
            '{"error":{"code":"REFRESH_TOKEN_REUSED","message":"reused"}}',
            401));
    expect(await api.restoreSession(), BusinessSessionRestore.invalid);
    expect(await store.session(), isNull);
  });
}
