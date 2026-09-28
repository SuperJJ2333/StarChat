import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics.dart';
import 'package:liuhetong_mobile/core/network_diagnostics.dart';
import 'package:liuhetong_mobile/core/network_request_diagnostics.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

void main() {
  test('client and server golden has exact immutable roundtrip', () {
    final golden = jsonDecode(
        File('test/core/fixtures/network_request_golden.json')
            .readAsStringSync()) as Map<String, dynamic>;
    expect(NetworkRequestDiagnosticSnapshot.tryParse(golden)!.toJson(), golden);
  });
  NetworkDiagnostics network() => NetworkDiagnostics()
    ..start(version: '0.4.17+2186', platform: 'android', generation: 1);
  DiagnosticHttpClient transport(NetworkDiagnostics n,
          Future<http.StreamedResponse> Function(http.BaseRequest) send) =>
      DiagnosticHttpClient(_StreamClient(send), () => n,
          primaryApiBaseUri: Uri.parse('https://primary.invalid'));
  final uri =
      Uri.parse('https://primary.invalid/api/v1/profile/me?email=private');
  for (final entry in <(Object, String)>[
    (const SocketException('private socket'), 'socket'),
    (const HandshakeException('private TLS'), 'tls'),
    (const HttpException('private transport'), 'http_transport'),
    (http.ClientException('private client'), 'http_transport'),
    (http.RequestAbortedException(), 'aborted'),
    (StateError('private unexpected'), 'unexpected'),
  ]) {
    test('typed ${entry.$2} failure is closed and rethrown unchanged',
        () async {
      final n = network();
      await expectLater(transport(n, (_) async => throw entry.$1).get(uri),
          throwsA(same(entry.$1)));
      final value = n.pendingRequests().single.toJson();
      expect(value['reason'], entry.$2);
      expect(value['phase'], 'awaiting_headers');
      expect(value['endpoint_category'], 'profile');
      expect(jsonEncode(value), isNot(contains('private')));
      expect(value.containsKey('http_status'), isFalse);
    });
  }
  test('body failure records headers and reading stage; 5xx is complete',
      () async {
    final n = network();
    final error = StateError('private body');
    await expectLater(
        transport(
            n,
            (_) async => http.StreamedResponse(
                  Stream.error(error),
                  200,
                )).get(uri),
        throwsA(same(error)));
    final body = n.pendingRequests().single.toJson();
    expect(body['phase'], 'reading_body');
    expect(body['http_status'], 200);
    expect(body['headers_ms'], lessThanOrEqualTo(body['elapsed_ms'] as int));
    await transport(
        n, (_) async => http.StreamedResponse(Stream.value([]), 503)).get(uri);
    final completed = n.pendingRequests().last.toJson();
    expect(completed['reason'], 'http_5xx');
    expect(completed['phase'], 'response_complete');
  });
  test('real default eight second deadline and late headers count once',
      () async {
    final n = network();
    final late = Completer<http.StreamedResponse>();
    await expectLater(
        transport(n, (_) => late.future)
            .get(uri)
            .timeout(const Duration(seconds: 8)),
        throwsA(isA<TimeoutException>()));
    final value = n.pendingRequests().single.toJson();
    expect(value['phase'], 'awaiting_headers');
    expect(value['timeout_budget_ms'], 8000);
    expect(value['timeout_lateness_ms'], greaterThanOrEqualTo(0));
    expect(value['elapsed_ms'], greaterThanOrEqualTo(7900));
    late.complete(http.StreamedResponse(Stream.value([]), 503));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(n.pendingRequests(), hasLength(1));
    expect(n.pending().single.toJson()['attempts'], 1);
  });
  test('body timeout preserves live stream and no second outcome', () async {
    final n = network();
    final stream = StreamController<List<int>>();
    await expectLater(
        transport(n, (_) async => http.StreamedResponse(stream.stream, 200))
            .get(uri)
            .timeout(const Duration(milliseconds: 5)),
        throwsA(isA<TimeoutException>()));
    expect(n.pendingRequests().single.toJson()['phase'], 'reading_body');
    stream.add([1]);
    await stream.close();
    expect(n.pendingRequests(), hasLength(1));
  });
  test('inactive, foreign origin and diagnostics upload are excluded',
      () async {
    final n = network();
    final headers = <String?>[];
    final client = transport(n, (r) async {
      headers.add(r.headers['X-ChatFlow-Request-Id']);
      throw const SocketException('hidden');
    });
    for (final url in [
      'https://foreign.invalid/api/v1/profile',
      'http://primary.invalid/api/v1/profile',
      'https://primary.invalid:444/api/v1/profile',
      'https://primary.invalid/api/v1/client-diagnostics'
    ]) {
      await expectLater(
          client.get(Uri.parse(url)), throwsA(isA<SocketException>()));
    }
    n.clear();
    await expectLater(client.get(uri), throwsA(isA<SocketException>()));
    expect(headers, everyElement(isNull));
    expect(n.hasPendingRequests, isFalse);
  });
  test(
      'closed parser and queue preserve IDs and reject private or invalid fields',
      () async {
    final n = network();
    final client =
        transport(n, (_) async => throw const SocketException('hidden'));
    await expectLater(client.get(uri), throwsA(isA<SocketException>()));
    final snapshot = n.pendingRequests().single;
    final valid = snapshot.toJson();
    for (final invalid in <Map<String, dynamic>>[
      {...valid, 'url': 'hidden'},
      {...valid, 'phase': 'dns'},
      {...valid, 'reason': 'hidden'},
      {...valid, 'elapsed_ms': true},
      {...valid, 'elapsed_ms': 3600001},
      {...valid, 'started_at': '2026-02-30T00:00:00Z'},
      {...valid, 'operation_id': 'account'},
      {...valid, 'headers_ms': -1},
      {...valid, 'headers_ms': (valid['elapsed_ms'] as int) + 1},
      {...valid, 'http_status': 600},
      {...valid, 'timeout_budget_ms': 8000},
      {...valid, 'phase': 'reading_body'},
      {...valid, 'phase': 'response_complete'},
      {...valid, 'request_id': '12345678-1234-1234-1234-123456789012'},
    ]) {
      expect(NetworkRequestDiagnosticSnapshot.tryParse(invalid), isNull);
    }
    valid['reason'] = 'hidden';
    expect(snapshot.toJson()['reason'], 'socket');
    n.restoreRequest(snapshot);
    expect(n.pendingRequests(), hasLength(1));
    for (var i = 0; i < 64; i++) {
      await expectLater(client.get(uri), throwsA(isA<SocketException>()));
    }
    expect(n.forRequestPersistence(), hasLength(64));
    expect(n.pendingRequests(limit: 100), hasLength(8));
    expect(n.droppedRequests, 1);
    n.acknowledgeRequests([snapshot]);
    expect(n.forRequestPersistence(), hasLength(63));
    n.disableRequests();
    await expectLater(client.get(uri), throwsA(isA<SocketException>()));
    expect(n.hasPendingRequests, isFalse);
    expect(n.hasPending, isTrue);
  });
  test('late completion cannot cross session generation', () async {
    final n = network();
    final late = Completer<http.StreamedResponse>();
    final result = transport(n, (_) => late.future).get(uri);
    n.start(version: '0.4.17+2186', platform: 'ios', generation: 2);
    late.complete(http.StreamedResponse(Stream.value([]), 503));
    await result;
    expect(n.hasPendingRequests, isFalse);
    expect(n.hasPending, isFalse);
  });
  test(
      'waiting timeout retains existing parent operation without altering audit',
      () async {
    final n = network();
    const operation = 'aabbccdd-0011-4a22-8b33-445566778899';
    final late = Completer<http.StreamedResponse>();
    final client = transport(n, (r) {
      r.headers['X-ChatFlow-Performance-Id'] = operation;
      expect(r.headers['X-Trace-Id'], 'kept-audit');
      return late.future;
    });
    await expectLater(
        client.get(uri, headers: {'X-Trace-Id': 'kept-audit'}).timeout(
            const Duration(milliseconds: 5)),
        throwsA(isA<TimeoutException>()));
    expect(n.pendingRequests().single.toJson()['operation_id'], operation);
    late.complete(http.StreamedResponse(Stream.value([]), 200));
    await Future<void>.delayed(Duration.zero);
  });
  test('401 authorized physical replay generates three independent IDs',
      () async {
    final original = ChatDiagnostics.instance;
    final diagnostics = ChatDiagnostics();
    ChatDiagnostics.instance = diagnostics;
    diagnostics.startSession(
        version: '0.4.17+2186',
        platform: ChatDiagnosticPlatform.android,
        upload: (_, __) async => 202);
    addTearDown(() {
      diagnostics.stopSession();
      ChatDiagnostics.instance = original;
    });
    final store = SecureSessionStore(_MemoryStore());
    await store.saveSession(
        accessToken: 'old', refreshToken: 'refresh', deviceKey: 'device');
    final ids = <String>[];
    final client = BusinessApiClient(
        baseUri: Uri.parse('https://primary.invalid'),
        sessionStore: store,
        client: _StreamClient((r) async {
          ids.add(r.headers['X-ChatFlow-Request-Id']!);
          if (r.url.path.endsWith('/auth/refresh')) {
            return http.StreamedResponse(
                Stream.value(utf8.encode(
                    '{"access_token":"new","refresh_token":"new-refresh"}')),
                200);
          }
          return http.StreamedResponse(Stream.value(utf8.encode('{}')),
              r.headers['Authorization'] == 'Bearer old' ? 401 : 200);
        }));
    await client.getJson('/api/v1/profile/me');
    expect(ids, hasLength(3));
    expect(ids.toSet(), hasLength(3));
  });
  test('active business request has a fresh closed correlation ID', () async {
    final original = ChatDiagnostics.instance;
    final diagnostics = ChatDiagnostics();
    ChatDiagnostics.instance = diagnostics;
    diagnostics.startSession(
      version: '0.4.17+2186',
      platform: ChatDiagnosticPlatform.android,
      upload: (_, __) async => 202,
    );
    addTearDown(() {
      diagnostics.stopSession();
      ChatDiagnostics.instance = original;
    });
    String? requestId;
    final client = BusinessApiClient(
      baseUri: Uri.parse('https://primary.invalid'),
      sessionStore: SecureSessionStore(_MemoryStore()),
      client: _StreamClient((request) async {
        requestId = request.headers['X-ChatFlow-Request-Id'];
        throw const SocketException('private target and credentials');
      }),
    );
    await expectLater(
        client.getJson('/api/v1/profile/me'), throwsA(isA<SocketException>()));
    expect(
        requestId,
        matches(RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        )));
  });
}

final class _StreamClient extends http.BaseClient {
  _StreamClient(this.respond);
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request);
}

final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}
