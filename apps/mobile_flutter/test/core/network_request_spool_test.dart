import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/core/chat_diagnostics.dart';
import 'package:liuhetong_mobile/core/network_diagnostics.dart';

void main() {
  test('retained old-release requests share the same sixty-four queue bound',
      () async {
    var now = DateTime.utc(2026, 9, 27);
    final spool = _Spool();
    final d = ChatDiagnostics(now: () => now);
    void start(String version) => d.startSession(
        version: version,
        platform: ChatDiagnosticPlatform.android,
        store: spool,
        spoolScope: () async => 'a' * 64,
        upload: (_, __) async => 503);
    start('0.4.17+2186');
    addTearDown(d.stopSession);
    await Future<void>.delayed(Duration.zero);
    final client = DiagnosticHttpClient(_FailClient(), () => d.networks,
        primaryApiBaseUri: Uri.parse('https://primary.invalid'));
    Future<void> fail() async => expectLater(
        client.get(Uri.parse('https://primary.invalid/api/v1/profile')),
        throwsA(isA<SocketException>()));
    for (var i = 0; i < 64; i++) {
      await fail();
    }
    now = now.add(const Duration(minutes: 1));
    await d.flush();
    await Future<void>.delayed(Duration.zero);
    start('0.4.18+2187');
    await Future<void>.delayed(Duration.zero);
    await fail();
    expect(d.networks.droppedRequests, 1);
    expect(d.networks.hasPendingRequests, isFalse);
  });
  test('request retry keeps immutable ID; 422 removes only new requests',
      () async {
    var now = DateTime.utc(2026, 9, 27);
    final batches = <Map<String, Object?>>[];
    var status = 503;
    final d = ChatDiagnostics(now: () => now);
    d.startSession(
        version: '0.4.17+2186',
        platform: ChatDiagnosticPlatform.android,
        upload: (batch, _) async {
          batches.add(batch.toJson());
          return status;
        });
    addTearDown(d.stopSession);
    final client = DiagnosticHttpClient(_FailClient(), () => d.networks,
        primaryApiBaseUri: Uri.parse('https://primary.invalid'));
    await expectLater(
        client.get(Uri.parse('https://primary.invalid/api/v1/profile')),
        throwsA(isA<SocketException>()));
    d.record(
        stage: ChatDiagnosticStage.matrixSend,
        error: ChatDiagnosticError.network);
    d.recordFrame(buildUs: 1, rasterUs: 1, budgetUs: 16667);
    now = now.add(const Duration(minutes: 1));
    await d.flush();
    expect(d.networks.hasPendingRequests, isTrue);
    now = now.add(const Duration(minutes: 1));
    status = 422;
    await d.flush();
    expect(batches[1]['network_requests'], batches[0]['network_requests']);
    expect(d.networks.hasPendingRequests, isFalse);
    expect(d.networks.hasPending, isTrue);
    now = now.add(const Duration(minutes: 1));
    status = 202;
    await d.flush();
    expect(batches.last.containsKey('network_requests'), isFalse);
    expect(batches.last['networks'], isNotEmpty);
    expect(batches.last['events'], isNotEmpty);
    expect(batches.last['frames'], isNotNull);
  });
  test('eight request and twenty total record budgets preserve overflow',
      () async {
    var now = DateTime.utc(2026, 9, 27);
    final batches = <Map<String, Object?>>[];
    final d = ChatDiagnostics(now: () => now);
    d.startSession(
        version: '0.4.17+2186',
        platform: ChatDiagnosticPlatform.android,
        upload: (batch, _) async {
          batches.add(batch.toJson());
          return 202;
        });
    addTearDown(d.stopSession);
    final client = DiagnosticHttpClient(_FailClient(), () => d.networks,
        primaryApiBaseUri: Uri.parse('https://primary.invalid'));
    for (var i = 0; i < 12; i++) {
      await expectLater(
          client.get(Uri.parse('https://primary.invalid/api/v1/profile')),
          throwsA(isA<SocketException>()));
    }
    for (var i = 0; i < 15; i++) {
      d.record(
          stage: ChatDiagnosticStage.matrixSend,
          error: ChatDiagnosticError.network,
          status: 400 + i);
    }
    now = now.add(const Duration(minutes: 1));
    await d.flush();
    expect(
        (batches.single['events'] as List).length +
            (batches.single['network_requests'] as List).length,
        20);
    expect(batches.single['network_requests'], hasLength(5));
    expect(utf8.encode(jsonEncode(batches.single)).length,
        lessThanOrEqualTo(16384));
    expect(d.networks.forRequestPersistence(), hasLength(7));
    now = now.add(const Duration(minutes: 1));
    await d.flush();
    expect(batches.last['network_requests'], hasLength(7));
  });
  test('same scoped spool restores original IDs and source after upgrade',
      () async {
    var now = DateTime.utc(2026, 9, 27);
    final spool = _Spool();
    final d = ChatDiagnostics(now: () => now);
    void start(
            String version, int status, List<Map<String, Object?>> batches) =>
        d.startSession(
            version: version,
            platform: ChatDiagnosticPlatform.android,
            store: spool,
            spoolScope: () async => 'a' * 64,
            upload: (batch, _) async {
              batches.add(batch.toJson());
              return status;
            });
    start('0.4.17+2186', 503, []);
    addTearDown(d.stopSession);
    await Future<void>.delayed(Duration.zero);
    final client = DiagnosticHttpClient(_FailClient(), () => d.networks,
        primaryApiBaseUri: Uri.parse('https://primary.invalid'));
    await expectLater(
        client.get(Uri.parse('https://primary.invalid/api/v1/profile')),
        throwsA(isA<SocketException>()));
    final id = d.networks.pendingRequests().single.requestId;
    now = now.add(const Duration(minutes: 1));
    await d.flush();
    await Future<void>.delayed(Duration.zero);
    expect(jsonDecode(spool.payload!)['network_requests'].single['request_id'],
        id);
    final batches = <Map<String, Object?>>[];
    now = now.add(const Duration(minutes: 1));
    start('0.4.18+2187', 202, batches);
    await Future<void>.delayed(Duration.zero);
    now = now.add(const Duration(minutes: 1));
    await d.flush();
    expect(batches.single['version'], '0.4.17+2186');
    expect(
        (batches.single['network_requests'] as List).single['request_id'], id);
    expect((batches.single['network_requests'] as List).single['version'],
        '0.4.17+2186');
    expect(jsonEncode(batches), isNot(contains('private')));
  });
  test('old generation upload acknowledgment cannot delete new failure',
      () async {
    var now = DateTime.utc(2026, 9, 27);
    final d = ChatDiagnostics(now: () => now);
    final waiting = Completer<int>();
    d.startSession(
        version: '0.4.17+2186',
        platform: ChatDiagnosticPlatform.android,
        upload: (_, __) => waiting.future);
    addTearDown(d.stopSession);
    final client = DiagnosticHttpClient(_FailClient(), () => d.networks,
        primaryApiBaseUri: Uri.parse('https://primary.invalid'));
    Future<void> fail() async => expectLater(
        client.get(Uri.parse('https://primary.invalid/api/v1/profile')),
        throwsA(isA<SocketException>()));
    await fail();
    now = now.add(const Duration(minutes: 1));
    final old = d.flush();
    d.startSession(
        version: '0.4.17+2186',
        platform: ChatDiagnosticPlatform.android,
        upload: (_, __) async => 202);
    await fail();
    final current = d.networks.pendingRequests().single.requestId;
    waiting.complete(202);
    await old;
    expect(d.networks.pendingRequests().single.requestId, current);
  });
  test('failure request is uploaded with the same ID and acknowledged on 202',
      () async {
    var now = DateTime.utc(2026, 9, 27);
    final batches = <Map<String, Object?>>[];
    final diagnostics = ChatDiagnostics(now: () => now);
    diagnostics.startSession(
        version: '0.4.17+2186',
        platform: ChatDiagnosticPlatform.android,
        upload: (b, _) async {
          batches.add(b.toJson());
          return 202;
        });
    addTearDown(diagnostics.stopSession);
    final client = DiagnosticHttpClient(
        _FailClient(), () => diagnostics.networks,
        primaryApiBaseUri: Uri.parse('https://primary.invalid'));
    await expectLater(
        client.get(Uri.parse('https://primary.invalid/api/v1/profile/me')),
        throwsA(isA<SocketException>()));
    final id = diagnostics.networks.pendingRequests().single.requestId;
    now = now.add(const Duration(minutes: 1));
    await diagnostics.flush();
    expect(batches.single['network_requests'], isA<List>());
    expect(
        (batches.single['network_requests'] as List).single['request_id'], id);
    expect(diagnostics.networks.hasPendingRequests, isFalse);
  });
}

final class _FailClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      throw const SocketException('private');
}

final class _Spool implements ChatDiagnosticSpoolStore {
  String? payload;
  @override
  Future<String?> read() async => payload;
  @override
  Future<void> write(String value) async => payload = value;
  @override
  Future<void> clear() async => payload = null;
}
