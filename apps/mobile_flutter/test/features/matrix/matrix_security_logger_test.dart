import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_security_logger.dart';

void main() {
  test('security lifecycle events contain only structured allowlisted fields',
      () {
    final output = <String>[];
    final logger = MatrixSecurityLogger(
      traceId: () => 'trace-test',
      sink: output.add,
    );

    logger.record(
      stage: MatrixSecurityStage.roomLeaseDrain,
      outcome: MatrixSecurityOutcome.timeout,
      code: MatrixSecurityCode.roomLeaseDrainTimeout,
    );

    expect(jsonDecode(output.single), {
      'trace_id': 'trace-test',
      'stage': 'room_lease_drain',
      'outcome': 'timeout',
      'code': 'E2EE_ROOM_LEASE_DRAIN_TIMEOUT',
    });
    expect(output.single, isNot(contains('exception')));
    expect(output.single, isNot(contains('room_id')));
  });
}
