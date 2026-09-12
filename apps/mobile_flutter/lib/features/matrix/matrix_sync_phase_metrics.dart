import 'package:matrix/matrix.dart' show SyncStatus;

import '../../core/performance_metrics.dart';

/// Bounded, local timing for a complete Matrix sync cycle.
///
/// It intentionally accepts only status transitions and elapsed microseconds:
/// no identifiers, request URLs, event content, or encryption material enter
/// diagnostics. A partial or malformed cycle is discarded.
final class MatrixSyncPhaseMetrics {
  MatrixSyncPhaseMetrics({
    PerformanceMetrics? metrics,
    int Function()? clockUs,
  })  : metrics = metrics ?? PerformanceMetrics.instance,
        _clockUs = clockUs ?? _defaultClockUs;

  final PerformanceMetrics metrics;
  final int Function() _clockUs;
  static final Stopwatch _clock = Stopwatch()..start();

  int? _waitingAt;
  int? _processingAt;
  int? _cleaningAt;
  bool _disposed = false;

  static int _defaultClockUs() => _clock.elapsedMicroseconds;

  void record(SyncStatus status) {
    if (_disposed || !metrics.enabled) return;
    final now = _clockUs();
    switch (status) {
      case SyncStatus.waitingForResponse:
        _waitingAt = now;
        _processingAt = null;
        _cleaningAt = null;
      case SyncStatus.processing:
        if (_waitingAt == null || _cleaningAt != null) {
          _clear();
        } else {
          _processingAt ??= now;
        }
      case SyncStatus.cleaningUp:
        if (_waitingAt == null || _processingAt == null) {
          _clear();
        } else {
          _cleaningAt ??= now;
        }
      case SyncStatus.finished:
        _finish(now);
      case SyncStatus.error:
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
    metrics.record(PerformanceOperation.syncResponseWait, processing - waiting);
    metrics.record(PerformanceOperation.syncProcessing, cleaning - processing);
    metrics.record(PerformanceOperation.syncCleanup, now - cleaning);
    _clear();
  }

  void _clear() {
    _waitingAt = null;
    _processingAt = null;
    _cleaningAt = null;
  }

  void dispose() {
    _disposed = true;
    _clear();
  }
}
