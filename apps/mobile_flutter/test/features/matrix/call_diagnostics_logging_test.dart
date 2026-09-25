import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/call_diagnostics.dart';

void main() {
  test('default call diagnostics retain stages without release detail logs',
      () {
    final previous = debugPrint;
    final lines = <String>[];
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    addTearDown(() => debugPrint = previous);
    final diagnostics = CallDiagnostics();

    diagnostics.mark(CallDiagStage.outgoingStart);

    expect(diagnostics.has(CallDiagStage.outgoingStart), isTrue);
    expect(lines, isEmpty);
  });

  test('explicit call diagnostics logger receives unified call tag', () {
    final lines = <String>[];
    final diagnostics = CallDiagnostics(log: lines.add);

    diagnostics.mark(CallDiagStage.outgoingStart);

    expect(lines, hasLength(1));
    expect(lines.single, startsWith('[chatflow/call]'));
    expect(diagnostics.summary(), startsWith('[chatflow/call]'));
  });
}
