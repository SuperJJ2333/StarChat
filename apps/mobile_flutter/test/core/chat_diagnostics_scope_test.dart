import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics_scope.dart';

void main() {
  testWidgets('scope clears diagnostics across account switch and disposal',
      (tester) async {
    final diagnostics = ChatDiagnostics();
    Widget scope(int epoch) => ChatDiagnosticsScope(
          diagnostics: diagnostics,
          sessionEpoch: epoch,
          version: '0.3.103+2152',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, abort) async => 202,
          child: const SizedBox(),
        );
    await tester.pumpWidget(scope(1));
    diagnostics.record(
        stage: ChatDiagnosticStage.matrixSend,
        error: ChatDiagnosticError.timeout);
    expect(diagnostics.pendingCount, 1);
    await tester.pumpWidget(scope(2));
    expect(diagnostics.pendingCount, 0);
    diagnostics.record(
        stage: ChatDiagnosticStage.framework,
        error: ChatDiagnosticError.unknown);
    await tester.pumpWidget(const SizedBox());
    expect(diagnostics.pendingCount, 0);
    diagnostics.record(
        stage: ChatDiagnosticStage.framework,
        error: ChatDiagnosticError.unknown);
    expect(diagnostics.pendingCount, 0);
  });
}
