import 'dart:convert';

/// A deliberately small, allowlisted lifecycle logger.
///
/// Callers cannot attach exception text, Matrix identifiers, event content, or
/// any key material. That keeps lifecycle diagnostics useful without crossing
/// the E2EE trust boundary.
enum MatrixSecurityStage {
  roomLeaseDrain('room_lease_drain'),
  lifecycle('lifecycle');

  const MatrixSecurityStage(this.value);
  final String value;
}

enum MatrixSecurityOutcome {
  success('success'),
  failure('failure'),
  timeout('timeout');

  const MatrixSecurityOutcome(this.value);
  final String value;
}

enum MatrixSecurityCode {
  roomLeaseDrainTimeout('E2EE_ROOM_LEASE_DRAIN_TIMEOUT'),
  roomLeaseDrainFailed('E2EE_ROOM_LEASE_DRAIN_FAILED'),
  lifecycleDrainTimeout('E2EE_LIFECYCLE_DRAIN_TIMEOUT'),
  lifecycleSuspendFailed('E2EE_LIFECYCLE_SUSPEND_FAILED'),
  lifecycleResumeRejectCloseFailed('E2EE_LIFECYCLE_RESUME_REJECT_CLOSE_FAILED'),
  homeResourceDisposeFailed('E2EE_HOME_RESOURCE_DISPOSE_FAILED');

  const MatrixSecurityCode(this.value);
  final String value;
}

final class MatrixSecurityLogger {
  const MatrixSecurityLogger({
    required String Function() traceId,
    required void Function(String line) sink,
  })  : _traceId = traceId,
        _sink = sink;

  final String Function() _traceId;
  final void Function(String line) _sink;

  void record({
    required MatrixSecurityStage stage,
    required MatrixSecurityOutcome outcome,
    required MatrixSecurityCode code,
  }) {
    _sink(jsonEncode({
      'trace_id': _traceId(),
      'stage': stage.value,
      'outcome': outcome.value,
      'code': code.value,
    }));
  }
}
