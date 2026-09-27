import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/business_api_error.dart';

/// Debug-only local diagnostics. Neither API accepts an ID, token, URI, message
/// body, exception string or stack trace.
enum MatrixSessionFailureBoundary {
  credentialsRead,
  confirmationRequest;

  String get wireName => switch (this) {
        credentialsRead => 'credentials_read',
        confirmationRequest => 'confirmation_request',
      };
}

enum MatrixSessionFailureCause {
  lifecycleRevoked,
  credentialsUnavailable,
  lifecycleDrainTimeout,
  socket,
  timeout,
  tls,
  transport,
  businessRejected,
  service,
  unknown;

  String get wireName => switch (this) {
        lifecycleRevoked => 'lifecycle_revoked',
        credentialsUnavailable => 'credentials_unavailable',
        lifecycleDrainTimeout => 'lifecycle_drain_timeout',
        businessRejected => 'business_rejected',
        _ => name,
      };
}

MatrixSessionFailureCause classifyMatrixSessionFailure(Object error) {
  if (error is StateError) {
    return switch (error.message) {
      'E2EE_LIFECYCLE_ACCESS_REVOKED' =>
        MatrixSessionFailureCause.lifecycleRevoked,
      'E2EE_LIFECYCLE_DRAIN_TIMEOUT' =>
        MatrixSessionFailureCause.lifecycleDrainTimeout,
      'Matrix session is unavailable' =>
        MatrixSessionFailureCause.credentialsUnavailable,
      _ => MatrixSessionFailureCause.unknown,
    };
  }
  if (error is SocketException) return MatrixSessionFailureCause.socket;
  if (error is TimeoutException) return MatrixSessionFailureCause.timeout;
  if (error is HandshakeException) return MatrixSessionFailureCause.tls;
  if (error is http.ClientException) return MatrixSessionFailureCause.transport;
  if (error is BusinessApiException) {
    return error.statusCode >= 500
        ? MatrixSessionFailureCause.service
        : MatrixSessionFailureCause.businessRejected;
  }
  return MatrixSessionFailureCause.unknown;
}

String formatMatrixSessionDiagnostic(
        MatrixSessionFailureBoundary boundary, Object error,
        {int? durationMs}) =>
    'chatflow/matrix stage=matrix_session boundary=${boundary.wireName} '
    'result=failed cause=${classifyMatrixSessionFailure(error).wireName}'
    '${durationMs == null ? '' : ' duration_ms=${durationMs.clamp(0, 600000)}'}';

/// `assert` removes this log call entirely from profile/release builds.
void recordMatrixSessionFailure(
    MatrixSessionFailureBoundary boundary, Object error,
    {int? durationMs}) {
  assert(() {
    debugPrint(
        formatMatrixSessionDiagnostic(boundary, error, durationMs: durationMs));
    return true;
  }());
}

void recordMatrixSessionSuccess(MatrixSessionFailureBoundary boundary,
    {required int durationMs}) {
  assert(() {
    debugPrint('chatflow/matrix stage=matrix_session '
        'boundary=${boundary.wireName} result=success '
        'duration_ms=${durationMs.clamp(0, 600000)}');
    return true;
  }());
}
