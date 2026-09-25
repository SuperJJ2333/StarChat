import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/business_api_performance_client.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

final class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.handle);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handle;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handle(request);
}

String? _header(http.BaseRequest request, String name) {
  for (final header in request.headers.entries) {
    if (header.key.toLowerCase() == name.toLowerCase()) return header.value;
  }
  return null;
}

void main() {
  test('a different recorder cannot inherit the page operation ID', () async {
    final pageRecorder =
        PerformanceTraceRecorder(metrics: PerformanceMetrics(enabled: true));
    final apiRecords = <PerformanceRecord>[];
    final apiRecorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true), onRecord: apiRecords.add);
    final page = pageRecorder.start(PerformanceOperationType.contactsLoad);
    final client = BusinessApiPerformanceClient(
      MockClient((_) async => http.Response('{}', 200)),
      recorder: apiRecorder,
    );

    await page.runChildOperations(
        () => client.get(Uri.parse('https://api.example/api/v1/contacts')));

    expect(apiRecords.single.operationId, isNot(page.operationId));
    page.dispose();
  });

  test('session generation drift cannot inherit an old operation ID', () async {
    var generation = 1;
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      sessionGeneration: () => generation,
      onRecord: records.add,
    );
    final page = recorder.start(PerformanceOperationType.contactsLoad);
    final client = BusinessApiPerformanceClient(
      MockClient((_) async => http.Response('{}', 200)),
      recorder: recorder,
    );
    generation = 2;

    await page.runChildOperations(
        () => client.get(Uri.parse('https://api.example/api/v1/contacts')));

    expect(records.single.operationId, isNot(page.operationId));
    page.dispose();
  });

  test('finished page scope does not lend its ID to later requests', () async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true), onRecord: records.add);
    final page = recorder.start(PerformanceOperationType.contactsLoad);
    page.finish();
    final client = BusinessApiPerformanceClient(
      MockClient((_) async => http.Response('{}', 200)),
      recorder: recorder,
    );

    await page.runChildOperations(
        () => client.get(Uri.parse('https://api.example/api/v1/contacts')));

    expect(records.last.operationId, isNot(page.operationId));
  });

  test('100 concurrent page operations keep API records on their own IDs',
      () async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      activeCapacity: 250,
      onRecord: records.add,
    );
    final entered = Completer<void>();
    var arrivals = 0;
    final headers = <int, String?>{};
    final client = BusinessApiPerformanceClient(
      MockClient((request) async {
        final index = int.parse(request.url.pathSegments.last);
        headers[index] = _header(request, 'X-ChatFlow-Performance-Id');
        if (++arrivals == 100) entered.complete();
        await entered.future;
        return http.Response('{}', 200);
      }),
      recorder: recorder,
    );
    final parents = List.generate(
        100, (_) => recorder.start(PerformanceOperationType.contactsLoad));

    await Future.wait(List.generate(100, (index) async {
      final parent = parents[index];
      await parent.runChildOperations(() =>
          client.get(Uri.parse('https://api.example/api/v1/contacts/$index')));
      parent.finish();
    }));

    expect(arrivals, 100);
    expect(parents.map((trace) => trace.operationId).toSet(), hasLength(100));
    for (var index = 0; index < 100; index++) {
      final id = parents[index].operationId;
      expect(headers[index], id);
      expect(
          records
              .where((record) => record.operationId == id)
              .map((record) => record.operation)
              .toSet(),
          {
            PerformanceOperationType.contactsLoad,
            PerformanceOperationType.apiRequest,
          });
    }
    expect(recorder.activeCount, 0);
  });

  test('authorized replay keeps the page operation ID across 401 retry',
      () async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true), onRecord: records.add);
    final store = SecureSessionStore(_MemoryStore());
    await store.saveSession(accessToken: 'old', refreshToken: 'valid');
    final apiHeaders = <String?>[];
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: store,
      performanceRecorder: recorder,
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/auth/refresh') {
          return http.Response(
              jsonEncode({'access_token': 'new', 'refresh_token': 'next'}),
              200);
        }
        apiHeaders.add(_header(request, 'X-ChatFlow-Performance-Id'));
        return apiHeaders.length == 1
            ? http.Response('{}', 401)
            : http.Response('{"available":"1.00"}', 200);
      }),
    );
    final page = recorder.start(PerformanceOperationType.walletLoad);

    await page.runChildOperations(api.caibiBalance);
    page.finish();

    final finance = records.singleWhere((record) =>
        record.endpointCategory == PerformanceEndpointCategory.finance);
    expect(finance.operationId, page.operationId);
    expect(finance.retryCount, 1);
    expect(apiHeaders, [page.operationId, page.operationId]);
    expect(
        records.where((record) =>
            record.operation == PerformanceOperationType.walletLoad),
        hasLength(1));
  });

  test('disabled recorder bypasses tracing work on the HTTP path', () async {
    String? receivedTraceHeader;
    String? receivedPerformanceHeader;
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: false),
      enabled: () => false,
      clockUs: () => throw StateError('disabled tracing must not read clock'),
      onRecord: (_) => throw StateError('disabled tracing must not record'),
    );
    final client = BusinessApiPerformanceClient(
      MockClient((request) async {
        receivedTraceHeader = _header(request, 'X-Trace-Id');
        receivedPerformanceHeader =
            _header(request, 'X-ChatFlow-Performance-Id');
        return http.Response('ok', 200);
      }),
      recorder: recorder,
    );

    final response = await client.get(
      Uri.parse('https://api.example/api/v1/profile/me'),
      headers: {'X-Trace-Id': 'caller-owned-value'},
    );
    expect(response.body, 'ok');
    expect(receivedTraceHeader, 'caller-owned-value');
    expect(receivedPerformanceHeader, isNull);
    expect(recorder.activeCount, 0);
  });

  test('shared HTTP seam times the completed body and stores typed metadata',
      () async {
    var clockUs = 0;
    String? receivedTraceHeader;
    String? receivedPerformanceHeader;
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => clockUs,
      onRecord: records.add,
    );
    final client = BusinessApiPerformanceClient(
      _StreamingClient((request) async {
        receivedTraceHeader = _header(request, 'X-Trace-Id');
        receivedPerformanceHeader =
            _header(request, 'X-ChatFlow-Performance-Id');
        clockUs = 100;
        return http.StreamedResponse(() async* {
          clockUs = 750;
          yield utf8.encode('{"ok":true}');
        }(), 200);
      }),
      recorder: recorder,
    );

    final response = await client.get(
      Uri.parse(
          'https://api.example/api/v1/moments/private-id?access_token=SECRET'),
      headers: {
        'X-Trace-Id': 'private-caller-header',
        'X-ChatFlow-Performance-Id': 'private-perf-caller',
      },
    );
    expect(response.body, '{"ok":true}');
    expect(records, hasLength(1));
    expect(records.single.totalUs, 750);
    expect(records.single.operation, PerformanceOperationType.apiRequest);
    expect(
        records.single.endpointCategory, PerformanceEndpointCategory.moments);
    expect(records.single.httpMethod, PerformanceHttpMethod.get);
    expect(records.single.statusCode, 200);
    expect(receivedTraceHeader, 'private-caller-header');
    expect(receivedPerformanceHeader, records.single.operationId);
    expect(receivedPerformanceHeader, isNot('private-perf-caller'));
    expect(records.single.serviceReachable, isTrue);
    expect(records.single.transportAvailable, isTrue);
    expect(records.single.stagesUs, contains(PerformanceStage.requestFinished));
    expect(jsonEncode(records.single.toJson()), isNot(contains('private-id')));
    expect(jsonEncode(records.single.toJson()), isNot(contains('SECRET')));
    expect(jsonEncode(records.single.toJson()),
        isNot(contains('private-perf-caller')));
  });

  test('authorized 401 refresh and replay retain one trace and retry count',
      () async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    );
    final store = SecureSessionStore(_MemoryStore());
    await store.saveSession(accessToken: 'expired-a', refreshToken: 'valid-r');
    var balanceCalls = 0;
    final financeTraceHeaders = <String?>[];
    String? refreshTraceHeader;
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: store,
      performanceRecorder: recorder,
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/auth/refresh') {
          refreshTraceHeader = _header(request, 'X-ChatFlow-Performance-Id');
          return http.Response(
              jsonEncode({'access_token': 'new-a', 'refresh_token': 'new-r'}),
              200);
        }
        balanceCalls++;
        financeTraceHeaders.add(_header(request, 'X-ChatFlow-Performance-Id'));
        if (balanceCalls == 1) return http.Response('{}', 401);
        return http.Response('{"available":"1.00"}', 200);
      }),
    );

    expect((await api.caibiBalance())['available'], '1.00');
    expect(balanceCalls, 2);
    final finance = records
        .where((record) =>
            record.endpointCategory == PerformanceEndpointCategory.finance)
        .toList();
    expect(finance, hasLength(1));
    expect(finance.single.statusCode, 200);
    expect(finance.single.retryCount, 1);
    expect(finance.single.result, PerformanceResult.success);
    expect(
        financeTraceHeaders, everyElement(equals(finance.single.operationId)));
    expect(refreshTraceHeader, isNot(finance.single.operationId));
    expect(
        records.where((record) =>
            record.endpointCategory == PerformanceEndpointCategory.auth),
        hasLength(1));
  });

  test('direct authentication request is measured without raw credentials',
      () async {
    final records = <PerformanceRecord>[];
    final store = SecureSessionStore(_MemoryStore());
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: store,
      performanceRecorder: PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true),
        onRecord: records.add,
      ),
      client: MockClient((_) async => http.Response(
            '{"access_token":"private-access","refresh_token":"private-refresh"}',
            200,
          )),
    );

    await api.loginBusiness(
      username: 'private-user',
      password: 'private-password',
      deviceKey: 'private-device',
      deviceName: 'test',
    );
    expect(records, hasLength(1));
    expect(records.single.endpointCategory, PerformanceEndpointCategory.auth);
    final encoded = jsonEncode(records.single.toJson());
    for (final secret in [
      'private-user',
      'private-password',
      'private-access',
      'private-refresh',
      'private-device',
    ]) {
      expect(encoded, isNot(contains(secret)));
    }
  });

  test('concurrent authorized requests keep their trace scopes separate',
      () async {
    final records = <PerformanceRecord>[];
    final store = SecureSessionStore(_MemoryStore());
    await store.saveSession(accessToken: 'old-a', refreshToken: 'old-r');
    final staleGate = Completer<void>();
    var staleRequests = 0;
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: store,
      performanceRecorder: PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true),
        onRecord: records.add,
      ),
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/auth/refresh') {
          return http.Response(
              '{"access_token":"new-a","refresh_token":"new-r"}', 200);
        }
        if (request.headers['authorization'] == 'Bearer old-a') {
          staleRequests++;
          if (staleRequests == 2) staleGate.complete();
          await staleGate.future;
          return http.Response('{}', 401);
        }
        return http.Response('{"ok":true}', 200);
      }),
    );

    await Future.wait([
      api.getJson('/friends/private-contact'),
      api.getJson('/moments/private-post'),
    ]);
    expect(staleRequests, 2);
    final operations = records
        .where((record) =>
            record.endpointCategory != PerformanceEndpointCategory.auth)
        .toList();
    expect(operations, hasLength(2));
    expect(operations.map((record) => record.endpointCategory).toSet(), {
      PerformanceEndpointCategory.friendship,
      PerformanceEndpointCategory.moments,
    });
    expect(
        operations.map((record) => record.operationId).toSet(), hasLength(2));
    expect(operations.every((record) => record.retryCount == 1), isTrue);
    final encoded =
        jsonEncode(operations.map((record) => record.toJson()).toList());
    expect(encoded, isNot(contains('private-contact')));
    expect(encoded, isNot(contains('private-post')));
  });

  test('typed transport and HTTP failures preserve truthful classification',
      () async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    );
    final failing = BusinessApiPerformanceClient(
      _StreamingClient(
          (_) async => throw const SocketException('socket closed')),
      recorder: recorder,
    );
    await expectLater(
      failing.get(Uri.parse('https://api.example/api/v1/profile/me')),
      throwsA(isA<SocketException>()),
    );
    expect(records.single.networkError, PerformanceNetworkError.socketFailure);
    expect(records.single.result, PerformanceResult.failed);
    expect(records.single.serviceReachable, isNull);

    final throttled = BusinessApiPerformanceClient(
      MockClient((_) async => http.Response('{}', 429)),
      recorder: recorder,
    );
    await throttled.get(Uri.parse('https://api.example/api/v1/profile/me'));
    expect(records.last.statusCode, 429);
    expect(records.last.networkError, PerformanceNetworkError.rateLimit);
    expect(records.last.serviceReachable, isTrue);
  });
}
