import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics.dart';
import 'package:liuhetong_mobile/core/chat_diagnostic_operation.dart';

void main() {
  test('records failure without changing the exception or late session',
      () async {
    final diagnostic = ChatDiagnostics();
    void start() => diagnostic.startSession(
        version: '0.3.103+2152',
        platform: ChatDiagnosticPlatform.ios,
        upload: (_, abort) async => 202);
    start();
    final error = TimeoutException('private detail must never be recorded');
    await expectLater(
        traceChatOperation(
            stage: ChatDiagnosticStage.sendAdmission,
            diagnostics: diagnostic,
            operation: () async => throw error),
        throwsA(same(error)));
    expect(diagnostic.pendingCount, 1);
    final pending = Completer<void>();
    final late = traceChatOperation(
        stage: ChatDiagnosticStage.sendAdmission,
        diagnostics: diagnostic,
        operation: () => pending.future);
    start();
    pending.completeError(error);
    await expectLater(late, throwsA(same(error)));
    expect(diagnostic.pendingCount, 0);
    await expectLater(
        traceChatOperation(
            stage: ChatDiagnosticStage.historySearch,
            diagnostics: diagnostic,
            isCancellation: (e) => identical(e, error),
            operation: () async => throw error),
        throwsA(same(error)));
    expect(diagnostic.pendingCount, 0,
        reason: 'user cancellation is not a fault');
    diagnostic.stopSession();
  });
}
