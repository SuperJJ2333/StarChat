import 'dart:async';
import 'dart:io';

import 'package:matrix/matrix.dart'
    show SyncStatus, SdkError, SyncConnectionException;

import '../../core/network_state_manager.dart';
import '../../core/performance_metrics.dart';
import '../../core/performance_trace.dart';

/// Typed local cumulative watchdog counters, never identity or error content.
final class MatrixSyncCounterSnapshot {
  const MatrixSyncCounterSnapshot(
      {required this.softKicks,
      required this.hardRestarts,
      required this.errors,
      required this.reconnects,
      this.lastHealthyAge});
  final int softKicks;
  final int hardRestarts;
  final int errors;
  final int reconnects;
  final Duration? lastHealthyAge;
}

/// Bounded, local timing for a complete Matrix sync cycle.
///
/// It accepts status transitions, typed counters and SDK exception types:
/// no identifiers, request URLs, event content, or encryption material enter
/// diagnostics. Malformed cycles are discarded; SDK errors close a partial
/// trace as failed while preserving the original complete-only phase metrics.
final class MatrixSyncPhaseMetrics {
  MatrixSyncPhaseMetrics({
    PerformanceMetrics? metrics,
    int Function()? clockUs,
    PerformanceTraceRecorder? traceRecorder,
  })  : metrics = metrics ?? PerformanceMetrics.instance,
        _clockUs = clockUs ?? _defaultClockUs,
        _traceRecorder = traceRecorder ?? PerformanceTraceRecorder.instance;

  final PerformanceMetrics metrics;
  final int Function() _clockUs;
  final PerformanceTraceRecorder _traceRecorder;
  static final Stopwatch _clock = Stopwatch()..start();

  int? _waitingAt;
  int? _processingAt;
  int? _cleaningAt;
  PerformanceTrace? _trace;
  MatrixSyncCounterSnapshot? _counterBaseline;
  bool _disposed = false;

  static int _defaultClockUs() => _clock.elapsedMicroseconds;

  void record(SyncStatus status,
      {SdkError? error, MatrixSyncCounterSnapshot? counters}) {
    if (_disposed ||
        (!metrics.enabled &&
            _trace == null &&
            !_traceRecorder.recordingEnabled)) {
      return;
    }
    // Trace-only diagnostics use the trace recorder's own monotonic clock.
    // A sentinel preserves transition validation without a second clock read.
    final now = metrics.enabled ? _clockUs() : 0;
    switch (status) {
      case SyncStatus.waitingForResponse:
        _clear();
        _waitingAt = now;
        _counterBaseline = counters;
        if (_traceRecorder.recordingEnabled) {
          _trace = _traceRecorder.start(PerformanceOperationType.matrixSync);
          _trace?.mark(PerformanceStage.syncResponseWaitStarted);
        }
      case SyncStatus.processing:
        if (_waitingAt == null || _cleaningAt != null) {
          _clear();
        } else if (_processingAt == null) {
          _processingAt = now;
          _trace?.mark(PerformanceStage.syncResponseReceived);
        }
      case SyncStatus.cleaningUp:
        if (_waitingAt == null || _processingAt == null) {
          _clear();
        } else if (_cleaningAt == null) {
          _cleaningAt = now;
          _trace?.mark(PerformanceStage.syncProcessingDone);
        }
      case SyncStatus.finished:
        _finish(now, counters);
      case SyncStatus.error:
        final trace = _trace ??
            (_traceRecorder.recordingEnabled
                ? _traceRecorder.start(PerformanceOperationType.matrixSync)
                : null);
        _trace = null;
        if (trace != null) {
          _applyCounters(trace, counters, actualError: true);
          if (error != null) {
            final measuredError = _networkError(error);
            trace.setNetwork(error: measuredError.$1);
            trace.statusCode = measuredError.$2;
          }
        }
        trace?.finish(result: PerformanceResult.failed);
        _clear();
    }
  }

  void _finish(int now, MatrixSyncCounterSnapshot? counters) {
    final waiting = _waitingAt;
    final processing = _processingAt;
    final cleaning = _cleaningAt;
    if (waiting == null ||
        processing == null ||
        cleaning == null ||
        processing < waiting ||
        cleaning < processing ||
        now < cleaning) {
      _clear();
      return;
    }
    if (metrics.enabled) {
      metrics.record(
          PerformanceOperation.syncResponseWait, processing - waiting);
      metrics.record(
          PerformanceOperation.syncProcessing, cleaning - processing);
      metrics.record(PerformanceOperation.syncCleanup, now - cleaning);
      metrics.record(PerformanceOperation.syncCycleTotal, now - waiting);
    }
    final trace = _trace;
    _trace = null;
    if (trace != null) _applyCounters(trace, counters);
    trace?.mark(PerformanceStage.syncCleanupDone);
    trace?.finish();
    _clear();
  }

  void _applyCounters(
      PerformanceTrace trace, MatrixSyncCounterSnapshot? current,
      {bool actualError = false}) {
    final baseline = _counterBaseline;
    if (current != null && baseline != null) {
      trace.softKickCount =
          (current.softKicks - baseline.softKicks).clamp(0, 1000000);
      trace.hardRestartCount =
          (current.hardRestarts - baseline.hardRestarts).clamp(0, 1000000);
      trace.syncErrorCount =
          (current.errors - baseline.errors).clamp(0, 1000000);
      trace.reconnectCount =
          (current.reconnects - baseline.reconnects).clamp(0, 1000000);
    } else if (actualError) {
      trace.syncErrorCount = 1;
    }
    trace.lastHealthySyncAgeMs = current?.lastHealthyAge?.inMilliseconds;
  }

  static (PerformanceNetworkError, int?) _networkError(SdkError sdkError) {
    Object? cause = sdkError.exception;
    if (cause is SyncConnectionException) cause = cause.originalException;
    final status = cause == null ? null : networkFailureHttpStatus(cause);
    final category = switch (cause) {
      TimeoutException() => PerformanceNetworkError.requestTimeout,
      SocketException() => PerformanceNetworkError.socketFailure,
      HandshakeException() => PerformanceNetworkError.tlsFailure,
      _ when status == 429 => PerformanceNetworkError.rateLimit,
      _ when status == 401 || status == 403 =>
        PerformanceNetworkError.authFailure,
      _ when status != null && status >= 500 =>
        PerformanceNetworkError.server5xx,
      _ when status != null && status >= 400 =>
        PerformanceNetworkError.businessRejection,
      _ => PerformanceNetworkError.unknown,
    };
    return (
      category,
      status != null && status >= 100 && status <= 599 ? status : null
    );
  }

  void _clear() {
    _trace?.dispose();
    _trace = null;
    _waitingAt = null;
    _processingAt = null;
    _cleaningAt = null;
    _counterBaseline = null;
  }

  void dispose() {
    _disposed = true;
    _clear();
  }
}
