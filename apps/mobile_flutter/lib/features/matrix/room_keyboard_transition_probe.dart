import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/performance_trace.dart';

/// Measures keyboard inset transitions without reading text or awaiting I/O.
final class RoomKeyboardTransitionProbe {
  RoomKeyboardTransitionProbe({
    required PerformanceTraceRecorder recorder,
    required double Function() bottomInset,
    required void Function(VoidCallback) afterFrame,
  })  : _recorder = recorder,
        _bottomInset = bottomInset,
        _afterFrame = afterFrame,
        _lastInset = _readInset(bottomInset);

  final PerformanceTraceRecorder _recorder;
  final double Function() _bottomInset;
  final void Function(VoidCallback) _afterFrame;
  double? _lastInset;
  double? _lastFrameInset;
  PerformanceTrace? _trace;
  PerformanceKeyboardDirection? _direction;
  Timer? _timeout;
  int _generation = 0;
  int _stableFrames = 0;
  bool _framePending = false;
  bool _disposed = false;

  static double? _readInset(double Function() read) {
    try {
      final inset = read();
      return inset.isFinite && inset >= 0 ? inset : null;
    } catch (_) {
      return null;
    }
  }

  static bool _atTarget(PerformanceKeyboardDirection direction, double inset) =>
      direction == PerformanceKeyboardDirection.show ? inset > 1 : inset <= 1;

  void request(PerformanceKeyboardDirection direction) {
    if (_disposed) return;
    final inset = _readInset(_bottomInset);
    if (inset == null) return;
    _lastInset = inset;
    if (_trace != null && _direction == direction) return;
    if (_trace != null) _finish(PerformanceResult.cancelled);
    if (_atTarget(direction, inset)) return;
    _begin(direction);
  }

  /// Called from the room's metrics observer; it schedules at most one frame.
  void onMetricsChanged() {
    if (_disposed) return;
    final inset = _readInset(_bottomInset);
    if (inset == null) {
      _finish(PerformanceResult.cancelled);
      return;
    }
    final previous = _lastInset;
    _lastInset = inset;
    if (_trace == null &&
        previous != null &&
        previous > 1 &&
        inset < previous - 1) {
      // System back can hide the keyboard without changing input focus.
      _begin(PerformanceKeyboardDirection.hide);
    }
    if (_trace != null) _scheduleFrame();
  }

  void _begin(PerformanceKeyboardDirection direction) {
    _generation++;
    _direction = direction;
    _stableFrames = 0;
    _lastFrameInset = null;
    _trace = _recorder.start(PerformanceOperationType.keyboardTransition);
    _trace?.keyboardDirection = direction;
    _trace?.mark(PerformanceStage.keyboardRequested);
    final generation = _generation;
    _timeout = Timer(const Duration(milliseconds: 1200), () {
      if (!_disposed && generation == _generation) {
        _finish(PerformanceResult.cancelled);
      }
    });
  }

  void _scheduleFrame() {
    if (_framePending || _trace == null || _disposed) return;
    _framePending = true;
    final generation = _generation;
    try {
      _afterFrame(() {
        if (_disposed || generation != _generation || _trace == null) return;
        _framePending = false;
        final inset = _readInset(_bottomInset);
        if (inset == null) {
          _finish(PerformanceResult.cancelled);
          return;
        }
        final direction = _direction!;
        final previous = _lastFrameInset;
        _lastFrameInset = inset;
        if (_atTarget(direction, inset)) {
          _stableFrames = previous == null || (previous - inset).abs() <= 1
              ? _stableFrames + 1
              : 1;
          if (_stableFrames >= 2) {
            _trace?.mark(PerformanceStage.keyboardStableFrame);
            _finish(PerformanceResult.success);
            return;
          }
          // Request one confirmation frame after the target inset is reached.
          _scheduleFrame();
        } else {
          _stableFrames = 0;
        }
        // Outside the target, wait for another metrics change. A stalled IME
        // must not drive a frame loop for the whole timeout window.
      });
    } catch (_) {
      _framePending = false;
      _finish(PerformanceResult.cancelled);
    }
  }

  void _finish(PerformanceResult result) {
    final trace = _trace;
    if (trace == null) return;
    _trace = null;
    _direction = null;
    _stableFrames = 0;
    _lastFrameInset = null;
    _framePending = false;
    _timeout?.cancel();
    _timeout = null;
    _generation++;
    trace.finish(result: result);
  }

  /// App backgrounding cancels the current sample while retaining the probe.
  void cancel() {
    if (_disposed) return;
    _finish(PerformanceResult.cancelled);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finish(PerformanceResult.cancelled);
    _generation++;
  }
}
