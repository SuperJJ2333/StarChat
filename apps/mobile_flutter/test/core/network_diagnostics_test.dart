import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:http/io_client.dart' show IOStreamedResponse;
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/core/network_diagnostics.dart';

final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  late DateTime now;
  late ChatDiagnostics diagnostics;
  late ChatDiagnostics original;
  late List<ChatDiagnosticBatch> batches;
  setUp(() {
    now = DateTime.utc(2026, 9, 26);
    original = ChatDiagnostics.instance;
    diagnostics = ChatDiagnostics(now: () => now);
    ChatDiagnostics.instance = diagnostics;
    batches = [];
    diagnostics.startSession(
      version: '1.2.3+45',
      platform: ChatDiagnosticPlatform.android,
      upload: (batch, _) async {
        batches.add(batch);
        return 202;
      },
    );
  });
  tearDown(() {
    diagnostics.stopSession();
    ChatDiagnostics.instance = original;
  });
  BusinessApiClient api(http.Client client) => BusinessApiClient(
    baseUri: Uri.parse('https://private.invalid'),
    sessionStore: SecureSessionStore(_MemoryStore()),
    client: client,
  );
  Future<void> flush() async {
    now = now.add(const Duration(minutes: 1));
    await diagnostics.flush();
  }

  Map sample(ChatDiagnosticBatch batch) =>
      (batch.toJson()['networks'] as List).single as Map;

  test('complete 200 and 401 both contribute their actual attempts', () async {
    var status = 200;
    final client = api(MockClient((_) async => http.Response('{}', status)));
    await client.getJson('/private/path');
    status = 401;
    await expectLater(
      client.getJson('/private/path'),
      throwsA(isA<Exception>()),
    );
    await flush();
    final value = sample(batches.single);
    expect(value['attempts'], 2);
    expect(value['http_2xx'], 1);
    expect(value['http_4xx'], 1);
    expect(value['network_errors'], 0);
    expect(value['success_latency_buckets'], [1, 0, 0, 0, 0, 0, 0, 0, 0]);
    expect(value['version'], '1.2.3+45');
    expect(value['platform'], 'android');
    expect(
      value['sample_id'],
      matches(RegExp(r'^[0-9a-f-]{14}4[0-9a-f-]{21}$')),
    );
    expect(value['window_start'], endsWith('Z'));
    expect(jsonEncode(value), isNot(contains('private')));
  });

  test('transport TimeoutException has a separate outcome', () async {
    final client = api(
      MockClient((_) async => throw TimeoutException('secret')),
    );
    await expectLater(
      client.getJson('/private'),
      throwsA(isA<TimeoutException>()),
    );
    await flush();
    expect(sample(batches.single)['timeouts'], 1);
    expect(sample(batches.single)['attempts'], 1);
  });

  test(
    'failed upload keeps immutable id while new attempts wait separately',
    () async {
      batches.clear();
      var status = 503;
      diagnostics.startSession(
        version: '1.2.3',
        platform: ChatDiagnosticPlatform.ios,
        upload: (batch, _) async {
          batches.add(batch);
          return status;
        },
      );
      final client = api(MockClient((_) async => http.Response('{}', 200)));
      await client.getJson('/a');
      await flush();
      final first = sample(batches.single);
      await client.getJson('/b');
      status = 202;
      await flush();
      final retried = (batches.last.toJson()['networks'] as List).first as Map;
      expect(retried, first);
      expect((batches.last.toJson()['networks'] as List), hasLength(2));
    },
  );

  test(
    '422 with networks preserves old events and frames on next cadence',
    () async {
      batches.clear();
      var status = 422;
      diagnostics.startSession(
        version: '1.2.3',
        platform: ChatDiagnosticPlatform.ios,
        upload: (batch, _) async {
          batches.add(batch);
          return status;
        },
      );
      diagnostics.record(
        stage: ChatDiagnosticStage.matrixSend,
        error: ChatDiagnosticError.network,
      );
      diagnostics.recordFrame(buildUs: 1, rasterUs: 1, budgetUs: 16667);
      await api(
        MockClient((_) async => http.Response('{}', 200)),
      ).getJson('/a');
      await flush();
      expect(batches.single.toJson()['networks'], isNotNull);
      status = 202;
      await flush();
      expect(batches.last.toJson().containsKey('networks'), isFalse);
      expect(
        (batches.last.toJson()['events'] as List).single['stage'],
        'matrixSend',
      );
      expect((batches.last.toJson()['frames'] as Map)['frame_count'], 1);
    },
  );

  test(
    'response finishing after account switch does not pollute fresh session',
    () async {
      final response = Completer<http.Response>();
      final client = api(MockClient((_) => response.future));
      final operation = client.getJson('/a');
      await Future<void>.delayed(Duration.zero);
      diagnostics.startSession(
        version: '1.2.4',
        platform: ChatDiagnosticPlatform.ios,
        upload: (batch, _) async {
          batches.add(batch);
          return 202;
        },
      );
      response.complete(http.Response('{}', 200));
      await operation;
      await flush();
      expect(batches, isEmpty);
    },
  );

  test(
    'old-session transport error cannot enter fresh legacy event channel',
    () async {
      final response = Completer<http.Response>();
      final client = api(MockClient((_) => response.future));
      final operation = client.getJson('/a');
      final error = expectLater(
        operation,
        throwsA(isA<http.ClientException>()),
      );
      await Future<void>.delayed(Duration.zero);
      diagnostics.startSession(
        version: '1.2.4',
        platform: ChatDiagnosticPlatform.ios,
        upload: (batch, _) async {
          batches.add(batch);
          return 202;
        },
      );
      response.completeError(http.ClientException('private failure'));
      await error;
      await flush();
      expect(batches, isEmpty);
    },
  );

  test(
    'logout serializes bounded queue loss using closed incomplete event',
    () async {
      final spool = _Spool();
      diagnostics.startSession(
        version: '1.2.3',
        platform: ChatDiagnosticPlatform.android,
        upload: (_, __) async => 503,
        store: spool,
        spoolScope: () async => 'a' * 64,
      );
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 40; i++) {
        diagnostics.networks.begin()!.complete(NetworkOutcome.http2xx);
        diagnostics.networks.freeze();
      }
      diagnostics.stopSession();
      await Future<void>.delayed(Duration.zero);
      final saved = jsonDecode(spool.payload!) as Map;
      final events = (saved['events'] as List).cast<Map>();
      expect(
        events,
        contains(
          predicate<Map>(
            (event) =>
                event['stage'] == 'network_request' &&
                event['error'] == 'incomplete' &&
                event['count'] == 8,
          ),
        ),
      );
    },
  );

  test(
    'external Future timeout counts once and late body cannot count success',
    () async {
      final body = StreamController<List<int>>();
      final client = DiagnosticHttpClient(
        _StreamClient(
          (request) async =>
              http.StreamedResponse(body.stream, 200, request: request),
        ),
        () => diagnostics.networks,
      );
      await expectLater(
        client
            .get(Uri.parse('https://private.invalid'))
            .timeout(const Duration(milliseconds: 1)),
        throwsA(isA<TimeoutException>()),
      );
      body.add(utf8.encode('{}'));
      await body.close();
      await Future<void>.delayed(Duration.zero);
      await flush();
      expect(sample(batches.single)['timeouts'], 1);
      expect(sample(batches.single)['http_2xx'], 0);
      expect(sample(batches.single)['attempts'], 1);
    },
  );

  test(
    'concurrent fast request is isolated from another request timeout',
    () async {
      final slow = Completer<http.StreamedResponse>();
      final client = DiagnosticHttpClient(
        _StreamClient((request) async {
          if (request.url.path == '/slow') return slow.future;
          return http.StreamedResponse(
            Stream.value(utf8.encode('{}')),
            200,
            request: request,
          );
        }),
        () => diagnostics.networks,
      );
      final timed = client
          .get(Uri.parse('https://private.invalid/slow'))
          .timeout(const Duration(milliseconds: 1));
      final fast = await client.get(Uri.parse('https://private.invalid/fast'));
      expect(fast.statusCode, 200);
      await expectLater(timed, throwsA(isA<TimeoutException>()));
      slow.complete(
        http.StreamedResponse(Stream.value(utf8.encode('{}')), 200),
      );
      await Future<void>.delayed(Duration.zero);
      await flush();
      expect(sample(batches.single)['attempts'], 2);
      expect(sample(batches.single)['http_2xx'], 1);
      expect(sample(batches.single)['timeouts'], 1);
    },
  );

  test(
    'success removes only sent snapshots while upload receives new attempts',
    () async {
      final flight = Completer<int>();
      diagnostics.startSession(
        version: '1.2.3',
        platform: ChatDiagnosticPlatform.android,
        upload: (batch, _) {
          batches.add(batch);
          return batches.length == 1 ? flight.future : Future.value(202);
        },
      );
      final client = api(MockClient((_) async => http.Response('{}', 200)));
      await client.getJson('/a');
      now = now.add(const Duration(minutes: 1));
      final uploading = diagnostics.flush();
      await client.getJson('/b');
      flight.complete(202);
      await uploading;
      await flush();
      expect(batches, hasLength(2));
      expect(sample(batches.first)['attempts'], 1);
      expect(sample(batches.last)['attempts'], 1);
      expect(
        sample(batches.first)['sample_id'],
        isNot(sample(batches.last)['sample_id']),
      );
    },
  );

  test(
    '401 refresh and authorized retry contribute three physical attempts',
    () async {
      final store = SecureSessionStore(_MemoryStore());
      await store.saveSession(
        accessToken: 'old',
        refreshToken: 'refresh',
        deviceKey: 'device',
      );
      var calls = 0;
      final client = BusinessApiClient(
        baseUri: Uri.parse('https://private.invalid'),
        sessionStore: store,
        client: MockClient((request) async {
          calls++;
          if (request.url.path.endsWith('/auth/refresh')) {
            return http.Response(
              '{"access_token":"new","refresh_token":"new-refresh"}',
              200,
            );
          }
          return http.Response(
            '{}',
            request.headers['Authorization'] == 'Bearer old' ? 401 : 200,
          );
        }),
      );
      await client.getJson('/a');
      await flush();
      expect(calls, 3);
      expect(sample(batches.single)['attempts'], 3);
      expect(sample(batches.single)['http_2xx'], 2);
      expect(sample(batches.single)['http_4xx'], 1);
    },
  );

  test(
    'network type is cached at attempt start and all statuses use separate outcomes',
    () async {
      var status = 302;
      final waiting = Completer<http.Response>();
      final client = api(
        MockClient(
          (_) => status == 302
              ? waiting.future
              : Future.value(http.Response('{}', status)),
        ),
      );
      diagnostics.networks.network = DiagnosticNetwork.wifi;
      final operation = client.getJson('/a');
      await Future<void>.delayed(Duration.zero);
      diagnostics.networks.network = DiagnosticNetwork.mobile;
      waiting.complete(http.Response('{}', 302));
      await operation;
      status = 503;
      await expectLater(client.getJson('/b'), throwsA(isA<Exception>()));
      await flush();
      final values = (batches.single.toJson()['networks'] as List).cast<Map>();
      expect(values.first['network'], 'wifi');
      expect(values.first['http_3xx'], 1);
      expect(values.last['network'], 'mobile');
      expect(values.last['http_5xx'], 1);
    },
  );

  test('clock moving backwards keeps UTC window ordered', () {
    final token = diagnostics.networks.begin()!;
    now = now.subtract(const Duration(hours: 1));
    token.complete(NetworkOutcome.http2xx);
    final value = diagnostics.networks.pending().single.toJson();
    expect(
      DateTime.parse(
        value['window_start'] as String,
      ).isAfter(DateTime.parse(value['window_end'] as String)),
      isFalse,
    );
  });

  test('typed abort at send is counted once as cancellation', () async {
    final client = DiagnosticHttpClient(
      _StreamClient(
        (request) async => throw http.RequestAbortedException(request.url),
      ),
      () => diagnostics.networks,
    );
    await expectLater(
      client.get(Uri.parse('https://private.invalid')),
      throwsA(isA<http.RequestAbortedException>()),
    );
    await flush();
    expect(sample(batches.single)['cancelled'], 1);
    expect(sample(batches.single)['attempts'], 1);
  });

  test(
    'IO response URL and socket detach remain delegated transport properties',
    () async {
      final original = _IoResponse(
        Stream.value([]),
        Uri.parse('https://private.invalid/final'),
      );
      final client = DiagnosticHttpClient(
        _StreamClient((_) async => original),
        () => diagnostics.networks,
      );
      final response = await client.send(
        http.Request('GET', Uri.parse('https://private.invalid')),
      );
      expect(response, isA<IOStreamedResponse>());
      expect(response, isA<http.BaseResponseWithUrl>());
      expect((response as http.BaseResponseWithUrl).url, original.url);
      await expectLater(
        (response as IOStreamedResponse).detachSocket(),
        throwsA(same(original.detached)),
      );
      expect(original.detachCalls, 1);
      await response.stream.drain<void>();
    },
  );

  test(
    '8 snapshots fit batch bound and returned histogram cannot mutate retry',
    () async {
      for (var i = 0; i < 10; i++) {
        diagnostics.networks.begin()!.complete(NetworkOutcome.http2xx);
        diagnostics.networks.freeze();
      }
      final values = diagnostics.networks.pending();
      expect(values, hasLength(8));
      final first = values.first.toJson();
      (first['success_latency_buckets'] as List<int>)[0] = 999;
      expect(values.first.toJson()['success_latency_buckets'], [
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
      ]);
      await flush();
      expect(
        utf8.encode(jsonEncode(batches.single.toJson())).length,
        lessThanOrEqualTo(16384),
      );
      expect(batches.single.toJson()['networks'], hasLength(8));
    },
  );

  test(
    'snapshot restore rejects free metadata, boolean counts and bad denominators',
    () {
      diagnostics.networks.begin()!.complete(NetworkOutcome.http2xx);
      final valid = diagnostics.networks.pending().single.toJson();
      expect(NetworkDiagnosticSnapshot.tryParse(valid), isNotNull);
      expect(
        NetworkDiagnosticSnapshot.tryParse({...valid, 'url': 'private'}),
        isNull,
      );
      expect(
        NetworkDiagnosticSnapshot.tryParse({...valid, 'attempts': true}),
        isNull,
      );
      expect(
        NetworkDiagnosticSnapshot.tryParse({...valid, 'attempts': 2}),
        isNull,
      );
      expect(
        NetworkDiagnosticSnapshot.tryParse({
          ...valid,
          'success_latency_buckets': List.filled(9, 0),
        }),
        isNull,
      );
      expect(
        NetworkDiagnosticSnapshot.tryParse({...valid, 'network': 'private'}),
        isNull,
      );
      expect(
        NetworkDiagnosticSnapshot.tryParse({
          ...valid,
          'window_end': '2020-01-01T00:00:00Z',
        }),
        isNull,
      );
      expect(
        NetworkDiagnosticSnapshot.tryParse({
          ...valid,
          'window_start': '2026-02-30T00:00:00Z',
        }),
        isNull,
      );
      expect(
        NetworkDiagnosticSnapshot.tryParse({
          ...valid,
          'window_start': '2026-09-25Z',
        }),
        isNull,
      );
      expect(
        NetworkDiagnosticSnapshot.tryParse({
          ...valid,
          'window_start': '2026-09-25T24:00:00Z',
        }),
        isNull,
      );
      expect(
        NetworkDiagnosticSnapshot.tryParse({
          ...valid,
          'window_start': '2026-09-25T00:00:00.1234567Z',
        }),
        isNull,
      );
      expect(
        NetworkDiagnosticSnapshot.tryParse({
          ...valid,
          'window_start': '2026-09-25T00:00:00+00:00',
        }),
        isNotNull,
      );
    },
  );

  test(
    'legacy schema1 cannot be restored without original source time',
    () async {
      final spool = _Spool()
        ..payload = jsonEncode({
          'schema': 1,
          'version': '1.2.3',
          'platform': 'android',
          'events': [
            {
              'operation_id': 'aabbccdd-0011-4a22-8b33-445566778899',
              'stage': 'network_request',
              'error': 'network',
              'elapsed_ms': 0,
              'count': 1,
              'status': null,
            },
          ],
        });
      diagnostics.startSession(
        version: '1.2.3',
        platform: ChatDiagnosticPlatform.android,
        upload: (batch, _) async {
          batches.add(batch);
          return 202;
        },
        store: spool,
        spoolScope: () async => 'a' * 64,
      );
      await Future<void>.delayed(Duration.zero);
      await flush();
      expect(batches, isEmpty);
      expect(spool.payload, isNull);
    },
  );

  test(
    'corrupt schema2 frame counters are dropped without poisoning uploader',
    () async {
      final spool = _Spool()
        ..payload = jsonEncode({
          'schema': 2,
          'batches': [
            {
              'version': '1.2.3',
              'platform': 'android',
              'window_start': '2026-09-25T00:00:00Z',
              'window_end': '2026-09-26T00:00:00Z',
              'events': [],
              'frames': {
                'frame_count': 1,
                'slow_frame_count': 0,
                'slow_build_count': 1,
                'slow_raster_count': 0,
              },
            },
          ],
        });
      diagnostics.startSession(
        version: '1.2.3',
        platform: ChatDiagnosticPlatform.android,
        upload: (batch, _) async {
          batches.add(batch);
          return 202;
        },
        store: spool,
        spoolScope: () async => 'a' * 64,
      );
      await Future<void>.delayed(Duration.zero);
      await flush();
      expect(batches, isEmpty);
      expect(spool.payload, isNull);
    },
  );

  test(
    'pausing and resuming preserve source backpressure and complete body once',
    () async {
      var pauses = 0, resumes = 0;
      final source = StreamController<List<int>>(
        onPause: () => pauses++,
        onResume: () => resumes++,
      );
      final client = DiagnosticHttpClient(
        _StreamClient((_) async => http.StreamedResponse(source.stream, 200)),
        () => diagnostics.networks,
      );
      final response = await client.send(
        http.Request('GET', Uri.parse('https://private.invalid')),
      );
      final received = <List<int>>[];
      final done = Completer<void>();
      final subscription = response.stream.listen(
        received.add,
        onDone: done.complete,
      );
      subscription.pause();
      source.add([1]);
      await Future<void>.delayed(Duration.zero);
      expect(pauses, 1);
      expect(received, isEmpty);
      subscription.resume();
      await Future<void>.delayed(Duration.zero);
      expect(resumes, 1);
      source.add([2]);
      await source.close();
      await done.future;
      expect(received, [
        [1],
        [2],
      ]);
      await flush();
      expect(sample(batches.single)['attempts'], 1);
      expect(sample(batches.single)['http_2xx'], 1);
    },
  );

  test(
    'stalled spool keeps latest snapshot with at most one queued replacement',
    () async {
      final spool = _SlowSpool();
      diagnostics.startSession(
        version: '1.2.3',
        platform: ChatDiagnosticPlatform.android,
        upload: (_, __) async => 503,
        store: spool,
        spoolScope: () async => 'a' * 64,
      );
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 3; i++) {
        diagnostics.networks.begin()!.complete(NetworkOutcome.http2xx);
        now = now.add(const Duration(minutes: 30));
        await diagnostics.flush();
      }
      diagnostics.stopSession();
      expect(spool.writes, 1);
      spool.release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(spool.writes, 2);
      final saved = jsonDecode(spool.payload!) as Map;
      final attempts = (saved['networks'] as List).cast<Map>().fold<int>(
        0,
        (sum, item) => sum + (item['attempts'] as int),
      );
      expect(attempts, 3);
    },
  );

  test(
    'body error is one network error and forwards unchanged response metadata',
    () async {
      final failure = StateError('private body failure');
      final client = DiagnosticHttpClient(
        _StreamClient(
          (request) async => http.StreamedResponse(
            Stream<List<int>>.error(failure),
            200,
            request: request,
            headers: {'x-test': 'kept'},
            isRedirect: true,
            persistentConnection: false,
            contentLength: 5,
            reasonPhrase: 'kept',
          ),
        ),
        () => diagnostics.networks,
      );
      final request = http.Request(
        'GET',
        Uri.parse('https://private.invalid/a'),
      );
      final response = await client.send(request);
      expect(response.request, same(request));
      expect(response.headers['x-test'], 'kept');
      expect(response.isRedirect, isTrue);
      expect(response.persistentConnection, isFalse);
      expect(response.contentLength, 5);
      expect(response.reasonPhrase, 'kept');
      await expectLater(response.stream.toBytes(), throwsA(same(failure)));
      await flush();
      expect(sample(batches.single)['network_errors'], 1);
      expect(sample(batches.single)['http_2xx'], 0);
    },
  );

  test(
    'cancelling body counts once; unconsumed body does not count completion',
    () async {
      final source = StreamController<List<int>>();
      final client = DiagnosticHttpClient(
        _StreamClient(
          (request) async =>
              http.StreamedResponse(source.stream, 200, request: request),
        ),
        () => diagnostics.networks,
      );
      final response = await client.send(
        http.Request('GET', Uri.parse('https://private.invalid')),
      );
      await flush();
      expect(batches, isEmpty);
      final subscription = response.stream.listen((_) {});
      await subscription.cancel();
      await source.close();
      await flush();
      expect(sample(batches.single)['cancelled'], 1);
      expect(sample(batches.single)['attempts'], 1);
    },
  );

  test(
    'all histogram boundaries are noncumulative and queue loss is bounded',
    () {
      final network = diagnostics.networks;
      for (final ms in [100, 250, 500, 1000, 2000, 5000, 10000, 30000, 30001]) {
        network.begin()!.complete(
          NetworkOutcome.http2xx,
          elapsed: Duration(milliseconds: ms),
        );
      }
      expect(
        network.pending().single.toJson()['success_latency_buckets'],
        List.filled(9, 1),
      );
      for (var i = 0; i < 40; i++) {
        network.begin()!.complete(NetworkOutcome.http4xx);
        network.freeze();
      }
      expect(network.persisted, hasLength(NetworkDiagnostics.maximumSnapshots));
      expect(network.droppedAttempts, 9);
    },
  );

  test(
    'spool preserves original event/frame version and network times after upgrade',
    () async {
      final spool = _Spool();
      diagnostics.startSession(
        version: '1.2.3',
        platform: ChatDiagnosticPlatform.android,
        upload: (_, __) async => 503,
        store: spool,
        spoolScope: () async => 'a' * 64,
      );
      diagnostics.record(
        stage: ChatDiagnosticStage.matrixSend,
        error: ChatDiagnosticError.network,
      );
      diagnostics.recordFrame(buildUs: 1, rasterUs: 1, budgetUs: 16667);
      await api(
        MockClient((_) async => http.Response('{}', 200)),
      ).getJson('/a');
      await flush();
      await Future<void>.delayed(Duration.zero);
      final saved = jsonDecode(spool.payload!) as Map;
      diagnostics.startSession(
        version: '1.2.4',
        platform: ChatDiagnosticPlatform.ios,
        upload: (batch, _) async {
          batches.add(batch);
          return 202;
        },
        store: spool,
        spoolScope: () async => 'a' * 64,
      );
      await Future<void>.delayed(Duration.zero);
      await flush();
      expect(batches.single.version, '1.2.3');
      expect(batches.single.platform, ChatDiagnosticPlatform.android);
      expect(sample(batches.single)['version'], '1.2.3');
      expect(
        sample(batches.single)['window_start'],
        '2026-09-26T00:00:00.000Z',
      );
      expect(jsonEncode(saved), isNot(contains('private')));
    },
  );
}

final class _StreamClient extends http.BaseClient {
  _StreamClient(this.respond);
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request);
}

class _Spool implements ChatDiagnosticSpoolStore {
  String? payload;
  @override
  Future<String?> read() async => payload;
  @override
  Future<void> write(String value) async {
    payload = value;
  }

  @override
  Future<void> clear() async {
    payload = null;
  }
}

final class _SlowSpool extends _Spool {
  final release = Completer<void>();
  int writes = 0;
  @override
  Future<void> write(String value) async {
    writes++;
    if (writes == 1) await release.future;
    await super.write(value);
  }
}

final class _IoResponse extends IOStreamedResponse
    implements http.BaseResponseWithUrl {
  _IoResponse(Stream<List<int>> stream, this.url) : super(stream, 200);
  @override
  final Uri url;
  final detached = StateError('detached sentinel');
  int detachCalls = 0;
  @override
  Future<Socket> detachSocket() async {
    detachCalls++;
    throw detached;
  }
}
