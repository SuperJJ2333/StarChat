import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'performance_trace.dart';

/// Observes the existing HTTP client at one shared seam. No URI, headers,
/// request body or response body are copied into a performance record.
final class BusinessApiPerformanceClient extends http.BaseClient {
  BusinessApiPerformanceClient(http.Client delegate,
      {PerformanceTraceRecorder? recorder})
      : _delegate = delegate,
        _recorder = recorder ?? PerformanceTraceRecorder.instance;

  final http.Client _delegate;
  final PerformanceTraceRecorder _recorder;
  final Object _scopeKey = Object();

  bool get enabled => _recorder.recordingEnabled;

  /// An authorized request can replay once after refreshing its credentials.
  /// The explicit scope merges only its HTTP attempts; the refresh request
  /// itself runs outside the scope and gets its own trace.
  BusinessApiPerformanceScope? beginLogicalRequest() =>
      enabled ? BusinessApiPerformanceScope._(this) : null;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!enabled) return _delegate.send(request);
    final scope = Zone.current[_scopeKey] as BusinessApiPerformanceScope?;
    final trace = scope?._traceFor(request) ?? _startTrace(request);
    if (!trace.isRecording) return _delegate.send(request);
    // The server's X-Trace-Id enters durable business/audit records. Keep it
    // untouched and use a separate, short-lived performance correlation ID.
    // Replace any caller-provided value so this header is always our UUID v4.
    request.headers.removeWhere(
        (name, _) => name.toLowerCase() == 'x-chatflow-performance-id');
    request.headers['X-ChatFlow-Performance-Id'] = trace.operationId;

    late final http.StreamedResponse response;
    try {
      response = await _delegate.send(request);
      // Receiving HTTP headers proves this Business API request reached a
      // service over a working transport, independent of Matrix sync state.
      trace.setNetwork(transport: true, service: true);
    } catch (error) {
      if (scope == null) {
        trace.mark(PerformanceStage.requestFinished);
        trace.finish(
          result: PerformanceResult.failed,
          networkError: _transportError(error),
        );
      } else {
        scope._observed(error: error);
      }
      rethrow;
    }

    Stream<List<int>> measuredBody() async* {
      Object? failure;
      var complete = false;
      try {
        yield* response.stream;
        complete = true;
      } catch (error) {
        failure = error;
        rethrow;
      } finally {
        if (scope == null) {
          trace.mark(PerformanceStage.requestFinished);
          trace.finish(
            result: complete
                ? _resultForStatus(response.statusCode)
                : failure == null
                    ? PerformanceResult.cancelled
                    : PerformanceResult.failed,
            statusCode: response.statusCode,
            networkError: failure == null
                ? complete
                    ? _statusError(response.statusCode)
                    : PerformanceNetworkError.cancelled
                : _transportError(failure),
          );
        } else {
          scope._observed(
            statusCode: response.statusCode,
            error: failure,
            cancelled: !complete && failure == null,
          );
        }
      }
    }

    return http.StreamedResponse(
      measuredBody(),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  PerformanceTrace _startTrace(http.BaseRequest request) => _recorder.start(
        PerformanceOperationType.apiRequest,
        parentOperation: PerformanceTrace.currentOperation,
        endpointCategory: _category(request.url),
        httpMethod: _method(request.method),
      );

  @override
  void close() => _delegate.close();
}

/// A single identity-free trace for the original and retried authorized call.
final class BusinessApiPerformanceScope {
  BusinessApiPerformanceScope._(this._client);

  final BusinessApiPerformanceClient _client;
  PerformanceTrace? _trace;
  int? _statusCode;
  Object? _requestFailure;
  bool _cancelled = false;
  int retryCount = 0;

  PerformanceTrace _traceFor(http.BaseRequest request) =>
      _trace ??= _client._startTrace(request);

  Future<T> run<T>(Future<T> Function() operation) => runZoned(
        operation,
        zoneValues: {_client._scopeKey: this},
      );

  void _observed({int? statusCode, Object? error, bool cancelled = false}) {
    _statusCode = statusCode;
    _requestFailure = error;
    _cancelled = cancelled;
  }

  void finish({Object? failure}) {
    final trace = _trace;
    if (trace == null || trace.isFinished) return;
    trace.mark(PerformanceStage.requestFinished);
    final error = failure ?? _requestFailure;
    trace.finish(
      result: _cancelled
          ? PerformanceResult.cancelled
          : error != null
              ? PerformanceResult.failed
              : _statusCode == null
                  ? PerformanceResult.failed
                  : _resultForStatus(_statusCode!),
      statusCode: _statusCode,
      retryCount: retryCount,
      networkError: _cancelled
          ? PerformanceNetworkError.cancelled
          : error == null
              ? _statusCode == null
                  ? PerformanceNetworkError.unknown
                  : _statusError(_statusCode!)
              : _transportError(error),
    );
  }
}

PerformanceEndpointCategory _category(Uri uri) {
  final segments = uri.pathSegments;
  final index =
      segments.length >= 3 && segments[0] == 'api' && segments[1] == 'v1'
          ? 2
          : 0;
  final segment = segments.length > index ? segments[index] : '';
  return switch (segment) {
    'auth' || 'invitations' => PerformanceEndpointCategory.auth,
    'profile' || 'users' => PerformanceEndpointCategory.profile,
    'contacts' ||
    'contact-tags' ||
    'blocks' =>
      PerformanceEndpointCategory.contacts,
    'friends' || 'friendships' => PerformanceEndpointCategory.friendship,
    'moments' => PerformanceEndpointCategory.moments,
    'wallet' ||
    'ledger' ||
    'caibi' ||
    'fx' ||
    'red-packets' ||
    'transfers' ||
    'recharges' ||
    'payouts' ||
    'withdrawals' =>
      PerformanceEndpointCategory.finance,
    'support' || 'complaints' => PerformanceEndpointCategory.support,
    'push' || 'presence' => PerformanceEndpointCategory.push,
    'media' || 'uploads' => PerformanceEndpointCategory.media,
    'client-diagnostics' => PerformanceEndpointCategory.diagnostics,
    _ => PerformanceEndpointCategory.other,
  };
}

PerformanceHttpMethod _method(String method) => switch (method) {
      'GET' => PerformanceHttpMethod.get,
      'POST' => PerformanceHttpMethod.post,
      'PUT' => PerformanceHttpMethod.put,
      'PATCH' => PerformanceHttpMethod.patch,
      'DELETE' => PerformanceHttpMethod.delete,
      'HEAD' => PerformanceHttpMethod.head,
      _ => PerformanceHttpMethod.other,
    };

PerformanceResult _resultForStatus(int status) => status >= 500
    ? PerformanceResult.failed
    : status >= 400
        ? PerformanceResult.rejected
        : PerformanceResult.success;

PerformanceNetworkError? _statusError(int status) => switch (status) {
      401 || 403 => PerformanceNetworkError.authFailure,
      429 => PerformanceNetworkError.rateLimit,
      >= 500 => PerformanceNetworkError.server5xx,
      >= 400 => PerformanceNetworkError.businessRejection,
      _ => null,
    };

/// `http.Client` has no DNS/connect/read phase API. A generic timeout or
/// ClientException cannot truthfully be assigned to one of those phases.
PerformanceNetworkError _transportError(Object error) => switch (error) {
      HandshakeException() ||
      TlsException() =>
        PerformanceNetworkError.tlsFailure,
      SocketException() => PerformanceNetworkError.socketFailure,
      _ => PerformanceNetworkError.unknown,
    };
