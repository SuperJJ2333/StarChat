import 'dart:convert';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics.dart';

void main() {
  test('refresh recovery uses closed metadata independent of credential nonce',
      () {
    fakeAsync((time) {
      final batches = <ChatDiagnosticBatch>[];
      final diagnostics =
          ChatDiagnostics(now: () => DateTime(2026).add(time.elapsed));
      diagnostics.startSession(
          version: '0.3.102',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, _) async {
            batches.add(batch);
            return 202;
          });
      diagnostics.record(
          stage: ChatDiagnosticStage.refreshRetryRecovered,
          error: ChatDiagnosticError.recovered,
          retryCount: 1,
          lifecycle: ChatDiagnosticLifecycle.foreground);
      time.elapse(const Duration(minutes: 1));
      final event = (batches.single.toJson()['events'] as List).single as Map;
      expect(event['stage'], 'retry_recovered');
      expect(event['retry_count'], 1);
      expect(event['lifecycle'], 'foreground');
      expect(event['operation_id'], matches(RegExp(r'^[a-f0-9-]{36}$')));
      expect(jsonEncode(event), isNot(contains('refresh_token')));
      diagnostics.stopSession();
    });
  });
}
