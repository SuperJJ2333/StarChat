import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/auth/login_stage_diagnostics.dart';

void main() {
  test('Matrix session diagnostic uses closed local boundary and cause', () {
    expect(
        classifyMatrixSessionFailure(
            StateError('E2EE_LIFECYCLE_ACCESS_REVOKED')),
        MatrixSessionFailureCause.lifecycleRevoked);
    expect(
        classifyMatrixSessionFailure(
            StateError('Matrix session is unavailable')),
        MatrixSessionFailureCause.credentialsUnavailable);
    expect(classifyMatrixSessionFailure(TimeoutException('secret-token')),
        MatrixSessionFailureCause.timeout);
    expect(classifyMatrixSessionFailure(const SocketException('secret-token')),
        MatrixSessionFailureCause.socket);

    final line = formatMatrixSessionDiagnostic(
        MatrixSessionFailureBoundary.credentialsRead,
        StateError('private-phone-code-token'));
    expect(line, contains('chatflow/matrix'));
    expect(line, contains('boundary=credentials_read'));
    expect(line, contains('cause=unknown'));
    expect(line, isNot(contains('private-phone-code-token')));
  });
}
