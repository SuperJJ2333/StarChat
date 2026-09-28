import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_failure.dart';
import 'package:liuhetong_mobile/core/startup_failure_metadata.dart';
import 'package:liuhetong_mobile/core/startup_diagnostics.dart';
import 'package:liuhetong_mobile/core/startup_diagnostics_spool.dart';
import 'package:liuhetong_mobile/core/startup_diagnostics_transport.dart';
import 'startup_diagnostics_spool_test.dart' show report;

final class MemorySpool implements StartupDiagnosticsSpool {
  List<Map<String, Object>> events = [];
  Completer<List<Map<String, Object>>>? pendingRead;
  Completer<void>? pendingWrite;
  bool readFails = false;
  int writes = 0;
  @override
  Future<List<Map<String, Object>>> read() async {
    if (readFails) throw StateError('unavailable');
    return pendingRead == null ? events : await pendingRead!.future;
  }

  @override
  Future<void> write(List<Map<String, Object>> value) async {
    writes++;
    if (pendingWrite != null) await pendingWrite!.future;
    events = value.map(Map<String, Object>.of).toList();
  }
}

final class Uploads implements StartupDiagnosticsTransport {
  final bodies = <Map<String, Object>>[];
  StartupDiagnosticsUploadResult result =
      StartupDiagnosticsUploadResult.accepted;
  Completer<StartupDiagnosticsUploadResult>? pending;
  @override
  Future<StartupDiagnosticsUploadResult> upload(Map<String, Object> event,
      {Future<void>? abort}) async {
    bodies.add(Map.of(event));
    return pending == null ? result : await pending!.future;
  }
}

void main() {
  final now = DateTime.utc(2026, 9, 27, 7, 1, 29);
  const failure = StartupFailureMetadata(
      category: SessionFailureCategory.unknown,
      boundary: StartupFailureBoundary.versionLoad);
  StartupDiagnostics create(MemorySpool spool, Uploads uploads,
      {DateTime Function()? clock, List<Duration> retries = const []}) {
    var id = 0;
    return StartupDiagnostics(
        spool: spool,
        transport: uploads,
        appVersion: '0.4.15',
        buildNumber: 2184,
        osVersion: 'iOS 18.1 private model',
        enabled: true,
        clock: clock ?? () => now,
        eventIdFactory: () =>
            '00000000-0000-4000-8000-${(++id).toString().padLeft(12, '0')}',
        ioTimeout: const Duration(milliseconds: 20),
        uploadTimeout: const Duration(milliseconds: 40),
        retryDelays: retries);
  }

  test('capture merges up to100 then freezes whole first attempted body',
      () async {
    final spool = MemorySpool();
    final uploads = Uploads()..result = StartupDiagnosticsUploadResult.retry;
    final diagnostics = create(spool, uploads);
    addTearDown(diagnostics.dispose);
    for (var i = 0; i < 101; i++) {
      diagnostics.record(StartupFailureStage.initialization, failure);
    }
    await diagnostics.initialize();
    await diagnostics.flush();
    expect(uploads.bodies.single['count'], 100);
    expect(uploads.bodies.single['occurred_at'], '2026-09-27T07:01:00Z');
    expect(uploads.bodies.single['os_version'], 'unknown');
    expect(uploads.bodies.single.keys.toSet(), {
      'schema',
      'platform',
      'event_id',
      'app_version',
      'build',
      'os_version',
      'occurred_at',
      'stage',
      'boundary',
      'category',
      'count'
    });
    diagnostics.record(StartupFailureStage.initialization, failure);
    await diagnostics.flush();
    expect(uploads.bodies[1], uploads.bodies.first);
    uploads.result = StartupDiagnosticsUploadResult.accepted;
    await diagnostics.flush();
    diagnostics.record(StartupFailureStage.initialization, failure);
    await diagnostics.flush();
    expect(uploads.bodies, hasLength(3));
    expect(spool.events, isEmpty);
  });
  test(
      'bounded spool timeout retains records and late read cannot overwrite memory',
      () async {
    final spool = MemorySpool()..pendingRead = Completer();
    final uploads = Uploads();
    final diagnostics = create(spool, uploads);
    addTearDown(diagnostics.dispose);
    diagnostics.record(StartupFailureStage.initialization, failure);
    await diagnostics.initialize().timeout(const Duration(seconds: 1));
    spool.pendingRead!.complete([report(index: 99)]);
    await diagnostics.flush();
    expect(uploads.bodies, hasLength(1));
    expect(uploads.bodies.single['event_id'], endsWith('000000000001'));
  });
  test(
      'concurrent records during read and upload survive accepted snapshot removal',
      () async {
    final spool = MemorySpool()..pendingRead = Completer();
    final uploads = Uploads()..pending = Completer();
    final diagnostics = create(spool, uploads);
    addTearDown(diagnostics.dispose);
    final init = diagnostics.initialize();
    diagnostics.record(StartupFailureStage.initialization, failure);
    spool.pendingRead!.complete([report(index: 99)]);
    await init;
    final flush = diagnostics.flush();
    await Future<void>.delayed(Duration.zero);
    diagnostics.record(
        StartupFailureStage.diagnosticSalt,
        const StartupFailureMetadata(
            category: SessionFailureCategory.platform,
            boundary: StartupFailureBoundary.diagnosticSalt));
    uploads.pending!.complete(StartupDiagnosticsUploadResult.accepted);
    await flush;
    expect(uploads.bodies, hasLength(3));
    expect(spool.events, isEmpty);
  });
  test('queue caps20 and expires24h without serializing extra fields',
      () async {
    final spool = MemorySpool()
      ..events = [for (var i = 1; i <= 25; i++) report(index: 100 + i)];
    final uploads = Uploads()..result = StartupDiagnosticsUploadResult.retry;
    var time = now;
    final diagnostics = create(spool, uploads, clock: () => time);
    addTearDown(diagnostics.dispose);
    await diagnostics.initialize();
    await diagnostics.flush();
    expect(spool.events, hasLength(20));
    expect(
        utf8.encode(jsonEncode(spool.events)).length, lessThanOrEqualTo(32768));
    time = time.add(const Duration(hours: 25));
    await diagnostics.flush();
    expect(spool.events, isEmpty);
  });
  test('finite retry budget and lifecycle flush retry same event', () async {
    final spool = MemorySpool();
    final uploads = Uploads()..result = StartupDiagnosticsUploadResult.retry;
    final diagnostics = create(spool, uploads, retries: const [
      Duration(milliseconds: 2),
      Duration(milliseconds: 2),
      Duration(milliseconds: 2)
    ]);
    addTearDown(diagnostics.dispose);
    diagnostics.record(StartupFailureStage.initialization, failure);
    await diagnostics.initialize();
    await diagnostics.flush();
    await Future<void>.delayed(const Duration(milliseconds: 35));
    expect(uploads.bodies, hasLength(4));
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(uploads.bodies, hasLength(4));
    uploads.result = StartupDiagnosticsUploadResult.accepted;
    await diagnostics.flush();
    expect(spool.events, isEmpty);
  });
  test('hung upload is bounded and disposal prevents retry and late removal',
      () async {
    final spool = MemorySpool();
    final uploads = Uploads()..pending = Completer();
    final diagnostics =
        create(spool, uploads, retries: const [Duration(milliseconds: 2)]);
    diagnostics.record(StartupFailureStage.initialization, failure);
    await diagnostics.initialize();
    final flush = diagnostics.flush();
    await Future<void>.delayed(Duration.zero);
    diagnostics.dispose();
    await flush.timeout(const Duration(seconds: 1));
    uploads.pending!.complete(StartupDiagnosticsUploadResult.accepted);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(uploads.bodies, hasLength(1));
    expect(spool.events, hasLength(1));
  });
  test('timed out uploader cannot cause overlapping retry requests', () async {
    final spool = MemorySpool();
    final uploads = Uploads()..pending = Completer();
    final diagnostics =
        create(spool, uploads, retries: const [Duration(milliseconds: 2)]);
    addTearDown(diagnostics.dispose);
    diagnostics.record(StartupFailureStage.initialization, failure);
    await diagnostics.initialize();
    await diagnostics.flush();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await diagnostics.flush();
    expect(uploads.bodies, hasLength(1));
    uploads.pending!.complete(StartupDiagnosticsUploadResult.retry);
    await Future<void>.delayed(Duration.zero);
    uploads.pending = null;
    uploads.result = StartupDiagnosticsUploadResult.accepted;
    await diagnostics.flush();
    expect(uploads.bodies, hasLength(2));
    expect(spool.events, isEmpty);
  });
  test('actual package version updates only pending unfrozen report metadata',
      () async {
    final spool = MemorySpool();
    final uploads = Uploads()..result = StartupDiagnosticsUploadResult.retry;
    final diagnostics = create(spool, uploads);
    addTearDown(diagnostics.dispose);
    diagnostics.record(StartupFailureStage.initialization, failure);
    diagnostics.updateVersion('0.4.16', 2185);
    await diagnostics.initialize();
    await diagnostics.flush();
    expect(uploads.bodies.single['app_version'], '0.4.16');
    expect(uploads.bodies.single['build'], 2185);
    diagnostics.updateVersion('0.4.17', 2186);
    await diagnostics.flush();
    expect(uploads.bodies[1], uploads.bodies[0]);
  });
  test('optional typed cause native status and login wrapper are closed fields',
      () async {
    final spool = MemorySpool();
    final uploads = Uploads();
    final diagnostics = create(spool, uploads);
    addTearDown(diagnostics.dispose);
    diagnostics.record(
        StartupFailureStage.sessionBootstrap,
        const StartupFailureMetadata(
            category: SessionFailureCategory.protectedData,
            boundary: StartupFailureBoundary.databaseKey,
            preflightCause: StartupIdentityCause.unreadable,
            nativeStatus: StartupNativeStatus.interactionNotAllowed,
            loginStage: StartupLoginStage.matrixLogin));
    await diagnostics.initialize();
    await diagnostics.flush();
    expect(uploads.bodies.single['preflight_cause'], 'unreadable');
    expect(uploads.bodies.single['native_status'], -25308);
    expect(uploads.bodies.single['login_stage'], 'L04');
    expect(uploads.bodies.single['boundary'], 'database_key');
  });
  test('disabled platform performs no IO and no network', () async {
    final spool = MemorySpool();
    final uploads = Uploads();
    final diagnostics = StartupDiagnostics(
        spool: spool,
        transport: uploads,
        appVersion: '0.4.15',
        buildNumber: 2184,
        osVersion: '18.1',
        enabled: false);
    diagnostics.record(StartupFailureStage.initialization, failure);
    await diagnostics.initialize();
    await diagnostics.flush();
    diagnostics.dispose();
    expect(uploads.bodies, isEmpty);
    expect(spool.events, isEmpty);
  });
  test('permanent rejection removes only that event', () async {
    final spool = MemorySpool();
    final uploads = Uploads()
      ..result = StartupDiagnosticsUploadResult.permanentFailure;
    final diagnostics = create(spool, uploads);
    addTearDown(diagnostics.dispose);
    diagnostics.record(StartupFailureStage.initialization, failure);
    await diagnostics.initialize();
    await diagnostics.flush();
    expect(uploads.bodies, hasLength(1));
    expect(spool.events, isEmpty);
  });
  test('never ending spool write does not block upload or startup capture',
      () async {
    final spool = MemorySpool()..pendingWrite = Completer();
    final uploads = Uploads();
    final diagnostics = create(spool, uploads);
    addTearDown(diagnostics.dispose);
    diagnostics.record(StartupFailureStage.initialization, failure);
    await diagnostics.initialize().timeout(const Duration(seconds: 1));
    await diagnostics.flush().timeout(const Duration(seconds: 1));
    expect(uploads.bodies, hasLength(1));
    spool.pendingWrite!.complete();
  });
  test('throwing clock cannot escape the synchronous observer boundary', () {
    final diagnostics = create(MemorySpool(), Uploads(),
        clock: () => throw StateError('private'));
    addTearDown(diagnostics.dispose);
    expect(
        () => diagnostics.record(StartupFailureStage.initialization, failure),
        returnsNormally);
  });
  test('failed read never overwrites temporarily inaccessible retained reports',
      () async {
    final spool = MemorySpool()
      ..events = [report(index: 99)]
      ..readFails = true;
    final uploads = Uploads();
    final diagnostics = create(spool, uploads);
    addTearDown(diagnostics.dispose);
    diagnostics.record(StartupFailureStage.initialization, failure);
    await diagnostics.initialize();
    await diagnostics.flush();
    expect(spool.writes, 0);
    expect(spool.events, [report(index: 99)]);
    expect(uploads.bodies, hasLength(1));
  });
  test(
      'per process signature admission is bounded while old duplicates stay suppressed',
      () async {
    final spool = MemorySpool();
    final uploads = Uploads();
    final diagnostics = create(spool, uploads);
    addTearDown(diagnostics.dispose);
    await diagnostics.initialize();
    for (var i = 0; i < 200; i++) {
      diagnostics.record(
          StartupFailureStage.values[i ~/ 30],
          StartupFailureMetadata(
              category: SessionFailureCategory.unknown,
              boundary: StartupFailureBoundary.values[i % 30]));
      await diagnostics.flush();
    }
    expect(uploads.bodies, hasLength(128));
    diagnostics.record(StartupFailureStage.initialization, failure);
    await diagnostics.flush();
    expect(uploads.bodies, hasLength(128));
  });
}
