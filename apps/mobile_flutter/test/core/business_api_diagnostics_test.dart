import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

class _MemoryStore implements SecureKeyValueStore {
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

ChatDiagnosticBatch batch() {
  late ChatDiagnosticBatch result;
  fakeAsync((time) {
    final diag = ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
    diag.startSession(
        version: '1.2.3',
        platform: ChatDiagnosticPlatform.ios,
        upload: (value, abort) async {
          result = value;
          return 202;
        });
    diag.record(
        stage: ChatDiagnosticStage.matrixSend,
        error: ChatDiagnosticError.network);
    time.elapse(const Duration(minutes: 1));
    diag.stopSession();
  });
  return result;
}

void main() {
  for (final error in [
    TimeoutException('private'),
    const SocketException('private')
  ]) {
    test('release metadata observes ${error.runtimeType} without payloads',
        () async {
      final original = ChatDiagnostics.instance;
      final diagnostics = ChatDiagnostics();
      ChatDiagnostics.instance = diagnostics;
      addTearDown(() {
        diagnostics.stopSession();
        ChatDiagnostics.instance = original;
      });
      diagnostics.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (_, __) async => 202);
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://private.example'),
          sessionStore: SecureSessionStore(_MemoryStore()),
          performanceRecorder: PerformanceTraceRecorder(
              metrics: PerformanceMetrics(enabled: false)),
          client: MockClient((_) async => throw error));
      await expectLater(api.getJson('/wallet/private'), throwsA(same(error)));
      expect(diagnostics.pendingCount, 1);
    });
  }
  test('late network failure cannot contaminate a newer diagnostics session',
      () async {
    final original = ChatDiagnostics.instance;
    final d = ChatDiagnostics();
    ChatDiagnostics.instance = d;
    addTearDown(() {
      d.stopSession();
      ChatDiagnostics.instance = original;
    });
    void start() => d.startSession(
        version: '1.2.3',
        platform: ChatDiagnosticPlatform.android,
        upload: (_, __) async => 202);
    start();
    final entered = Completer<void>();
    final pending = Completer<http.Response>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://private.example'),
        sessionStore: SecureSessionStore(_MemoryStore()),
        performanceRecorder: PerformanceTraceRecorder(
            metrics: PerformanceMetrics(enabled: false)),
        client: MockClient((_) {
          entered.complete();
          return pending.future;
        }));
    final request = api.getJson('/private');
    final result = expectLater(request, throwsA(isA<SocketException>()));
    await entered.future;
    start();
    pending.completeError(const SocketException('private'));
    await result;
    expect(d.pendingCount, 0);
  });
  test(
      'singleton replacement rejects a late request even when former recorder remains active',
      () async {
    final original = ChatDiagnostics.instance;
    final old = ChatDiagnostics(), fresh = ChatDiagnostics();
    addTearDown(() {
      old.stopSession();
      fresh.stopSession();
      ChatDiagnostics.instance = original;
    });
    for (final d in [old, fresh]) {
      d.startSession(
          version: '1.2.3',
          platform: ChatDiagnosticPlatform.android,
          upload: (_, __) async => 202);
    }
    ChatDiagnostics.instance = old;
    final entered = Completer<void>(), pending = Completer<http.Response>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://private.example'),
        sessionStore: SecureSessionStore(_MemoryStore()),
        performanceRecorder: PerformanceTraceRecorder(
            metrics: PerformanceMetrics(enabled: false)),
        client: MockClient((_) {
          entered.complete();
          return pending.future;
        }));
    final request = api.getJson('/private');
    final result = expectLater(request, throwsA(isA<SocketException>()));
    await entered.future;
    ChatDiagnostics.instance = fresh;
    pending.completeError(const SocketException('private'));
    await result;
    expect(old.pendingCount, 0);
    expect(fresh.pendingCount, 0);
  });
  test('real 401 is recorded without changing existing authentication policy',
      () async {
    final original = ChatDiagnostics.instance;
    var now = DateTime(2026);
    final d = ChatDiagnostics(now: () => now);
    ChatDiagnostics.instance = d;
    addTearDown(() {
      d.stopSession();
      ChatDiagnostics.instance = original;
    });
    final batches = <ChatDiagnosticBatch>[];
    d.startSession(
        version: '1.2.3',
        platform: ChatDiagnosticPlatform.android,
        upload: (b, _) async {
          batches.add(b);
          return 202;
        });
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://private.example'),
        sessionStore: SecureSessionStore(_MemoryStore()),
        performanceRecorder: PerformanceTraceRecorder(
            metrics: PerformanceMetrics(enabled: false)),
        client: MockClient((_) async => http.Response('{}', 401)));
    await expectLater(api.getJson('/private'), throwsA(isA<Exception>()));
    now = now.add(const Duration(minutes: 1));
    await d.flush();
    final event = (batches.single.toJson()['events'] as List).single as Map;
    expect(event['stage'], 'network_request');
    expect(event['error'], 'rejected');
    expect(event['status'], 401);
  });
  for (final status in [202, 401, 429]) {
    test('dedicated transport $status does not refresh or invalidate session',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final store = SecureSessionStore(_MemoryStore());
      final performance = <PerformanceRecord>[];
      await store.saveSession(
          accessToken: 'test-token',
          refreshToken: 'refresh-secret',
          matrixUserId: '@private:test');
      var requests = 0;
      server.listen((request) async {
        requests++;
        expect(request.uri.path, '/api/v1/client-diagnostics');
        expect(request.headers.value('authorization'), 'Bearer test-token');
        final payload = await utf8.decoder.bind(request).join();
        expect(payload, isNot(contains('private')));
        expect(payload, isNot(contains('secret')));
        request.response.statusCode = status;
        await request.response.close();
      });
      final api = BusinessApiClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
          sessionStore: store,
          performanceRecorder: PerformanceTraceRecorder(
              metrics: PerformanceMetrics(enabled: true),
              onRecord: performance.add));
      var invalidations = 0;
      final subscription =
          api.sessionInvalidations.listen((_) => invalidations++);
      addTearDown(subscription.cancel);
      expect(await api.uploadChatDiagnostics(batch(), Completer<void>().future),
          status);
      expect(requests, 1);
      expect(performance, isEmpty,
          reason: 'diagnostic upload must not recursively record itself');
      expect(invalidations, 0);
      expect((await store.session())?.accessToken, 'test-token');
      expect((await store.session())?.refreshToken, 'refresh-secret');
    });
  }

  test('abort closes stalled socket and completes without auth side effects',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = Completer<HttpRequest>();
    server.listen(received.complete);
    final store = SecureSessionStore(_MemoryStore());
    await store.saveSession(accessToken: 'test-token', refreshToken: 'r');
    final api = BusinessApiClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        sessionStore: store);
    final abort = Completer<void>();
    final result = api.uploadChatDiagnostics(batch(), abort.future);
    final request = await received.future;
    // Detach the HTTP socket to observe actual peer closure, not only Future timeout.
    final socket = await request.response.detachSocket(writeHeaders: false);
    final disconnected = socket.drain<void>();
    abort.complete();
    expect(await result.timeout(const Duration(seconds: 2)), 0);
    await disconnected.timeout(const Duration(seconds: 2));
    socket.destroy();
  });

  test('five-second deadline actually closes unresponsive transport', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = Completer<HttpRequest>();
    server.listen(received.complete);
    final store = SecureSessionStore(_MemoryStore());
    await store.saveSession(accessToken: 'test-token', refreshToken: 'r');
    final api = BusinessApiClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        sessionStore: store);
    final watch = Stopwatch()..start();
    final result = api.uploadChatDiagnostics(batch(), Completer<void>().future);
    final socket = await (await received.future)
        .response
        .detachSocket(writeHeaders: false);
    final disconnected = socket.drain<void>();
    expect(await result, 0);
    expect(watch.elapsedMilliseconds, inInclusiveRange(4500, 6500));
    await disconnected.timeout(const Duration(seconds: 2));
    socket.destroy();
  });
}
