import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics.dart';
import 'package:liuhetong_mobile/core/network_diagnostics.dart';

final class _Spool implements ChatDiagnosticSpoolStore {
  String? payload;
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async => payload = value;
  @override
  Future<void> clear() async => payload = null;
}

void main() {
  test('frequent spool writes retain all requests until the minute upload', () {
    fakeAsync((clock) {
      final spool = _Spool();
      final uploaded = <Map<String, Object?>>[];
      final diagnostics = ChatDiagnostics(
        now: () => DateTime.utc(2026, 9, 27).add(clock.elapsed),
      );
      diagnostics.startSession(
        version: '0.4.16+2185',
        platform: ChatDiagnosticPlatform.android,
        store: spool,
        spoolScope: () async => 'a' * 64,
        upload: (batch, _) async {
          uploaded.add(batch.toJson());
          return 202;
        },
      );
      clock.flushMicrotasks();
      for (var i = 0; i < 55; i++) {
        diagnostics.networks.begin()!.complete(NetworkOutcome.http2xx);
        diagnostics.record(
          stage: ChatDiagnosticStage.framework,
          error: ChatDiagnosticError.unknown,
        );
        clock.elapse(const Duration(seconds: 1));
        clock.flushMicrotasks();
      }
      final dropped = diagnostics.networks.droppedAttempts;
      clock.elapse(const Duration(seconds: 5));
      clock.flushMicrotasks();
      final attempts = uploaded
          .expand((batch) => (batch['networks'] as List?) ?? const [])
          .cast<Map>()
          .fold<int>(0, (total, row) => total + (row['attempts'] as int));
      diagnostics.stopSession();
      clock.flushMicrotasks();
      expect(dropped, 0, reason: 'Persistence must not exhaust snapshot slots');
      expect(attempts, 55);
    });
  });

  test('session stop persists the unfinished short network window', () {
    fakeAsync((clock) {
      final spool = _Spool();
      final diagnostics = ChatDiagnostics(
        now: () => DateTime.utc(2026, 9, 27).add(clock.elapsed),
      );
      diagnostics.startSession(
        version: '0.4.16+2185',
        platform: ChatDiagnosticPlatform.android,
        store: spool,
        spoolScope: () async => 'b' * 64,
        upload: (_, __) async => 202,
      );
      clock.flushMicrotasks();
      for (var i = 0; i < 5; i++) {
        diagnostics.networks.begin()!.complete(NetworkOutcome.http2xx);
      }
      diagnostics.stopSession();
      clock.flushMicrotasks();
      final saved = jsonDecode(spool.payload!) as Map;
      expect(
        (saved['networks'] as List)
            .cast<Map>()
            .fold<int>(0, (total, row) => total + (row['attempts'] as int)),
        5,
      );
    });
  });
}
