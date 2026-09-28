import 'dart:async';

import '../../core/performance_trace.dart';

/// Records visible room-route frames without retaining the room or route.
final class RoomRouteFrameProbe {
  RoomRouteFrameProbe(this._recorder);

  final PerformanceTraceRecorder _recorder;
  PerformanceTrace? _trace;
  PerformanceRoomRoutePhase? _phase;
  Timer? _timeout;
  int _generation = 0;
  bool _disposed = false;
  bool _invalidated = false;

  void beginEnter() => _begin(PerformanceRoomRoutePhase.enter);

  void beginLeave() => _begin(PerformanceRoomRoutePhase.leave);

  void _begin(PerformanceRoomRoutePhase phase) {
    if (_disposed || _invalidated) return;
    if (_trace != null && _phase == phase) return;
    cancel();
    _phase = phase;
    _trace = _recorder.start(PerformanceOperationType.roomLocalFrame);
    _trace?.roomRoutePhase = phase;
    if (phase == PerformanceRoomRoutePhase.leave) {
      _trace?.mark(PerformanceStage.routeExitRequested);
    }
    final generation = ++_generation;
    _timeout = Timer(const Duration(milliseconds: 1200), () {
      if (!_disposed && generation == _generation) cancel();
    });
  }

  void onRoomFirstFrame() {
    if (_disposed || _phase != PerformanceRoomRoutePhase.enter) return;
    _trace?.mark(PerformanceStage.roomLocalFirstFrame);
    _finish(PerformanceResult.success);
  }

  void onRouteExitFrame() {
    if (_disposed || _phase != PerformanceRoomRoutePhase.leave) return;
    _trace?.mark(PerformanceStage.routeExitFrame);
    _finish(PerformanceResult.success);
  }

  void cancel() => _finish(PerformanceResult.cancelled);

  /// Revoked or replaced routes can never produce another visible frame.
  void invalidate() {
    if (_disposed || _invalidated) return;
    _invalidated = true;
    cancel();
  }

  void _finish(PerformanceResult result) {
    final trace = _trace;
    if (trace == null) return;
    _trace = null;
    _phase = null;
    _timeout?.cancel();
    _timeout = null;
    _generation++;
    trace.finish(result: result);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancel();
    _generation++;
  }
}
