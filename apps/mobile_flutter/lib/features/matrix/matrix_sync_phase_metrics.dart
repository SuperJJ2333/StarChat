import 'package:matrix/matrix.dart' show SyncStatus;

import '../../core/performance_metrics.dart';
import '../../core/performance_trace.dart';

/// Bounded, local timing for a complete Matrix sync cycle.
///
/// It intentionally accepts only status transitions and elapsed microseconds:
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
  bool _disposed = false;

  static int _defaultClockUs() => _clock.elapsedMicroseconds;

  void record(SyncStatus status) {
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
        if (_traceRecorder.recordingEnabled) {
          _trace = _traceRecorder.start(PerformanceOperationType.matrixSync);
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
        _finish(now);
      case SyncStatus.error:
        final trace = _trace;
        _trace = null;
        trace?.finish(result: PerformanceResult.failed);
        _clear();
    }
  }

  void _finish(int now) {
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
    trace?.mark(PerformanceStage.syncCleanupDone);
    trace?.finish();
    _clear();
  }

  void _clear() {
    _trace?.dispose();
    _trace = null;
    _waitingAt = null;
    _processingAt = null;
    _cleaningAt = null;
  }

  void dispose() {
    _disposed = true;
    _clear();
  }
}
