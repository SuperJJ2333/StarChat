import 'dart:async';

/// Grants the newest video activation exclusive permission to start playback.
///
/// A reservation is published synchronously, then waits for every earlier
/// reservation's pause barrier before its owner can call the native player.
final class VideoPlaybackArbiter {
  VideoPlaybackReservation? _current;
  Future<void>? _pendingPauseBarrier;
  Future<void> Function()? _retryPause;
  var _nextToken = 0;

  int get debugPendingBarrierCount => _pendingPauseBarrier == null ? 0 : 1;
  bool get debugHasCurrent => _current != null;
  bool get debugHasPendingBarrier => _pendingPauseBarrier != null;
  bool get debugHasRetryPause => _retryPause != null;

  VideoPlaybackReservation reserve(
      Object owner, Future<void> Function() pause) {
    final previous = _current;
    final previousPause = previous != null && !identical(previous._owner, owner)
        ? previous.pauseForRetry()
        : null;
    final pauses = <Future<void> Function()>[
      if (_retryPause != null) _retryPause!,
      if (previousPause != null) previousPause,
    ];
    final reservation = VideoPlaybackReservation._(
      this,
      owner,
      ++_nextToken,
      _pendingPauseBarrier,
      pauses,
      pause,
    );
    _current = reservation;
    final barrier = reservation._startPauseBarrier();
    _pendingPauseBarrier = barrier;
    barrier.then(
      (_) {
        _clearPendingBarrier(barrier);
        if (identical(_retryPause, reservation._retriedPause)) {
          _retryPause = null;
        }
        reservation._clearCompletedPriorState();
      },
      onError: (_, __) {
        _clearPendingBarrier(barrier);
        final failedPause = reservation._failedPause;
        if (failedPause != null) _retryPause = failedPause;
        reservation._clearCompletedPriorState();
      },
    );
    return reservation;
  }

  void _clearPendingBarrier(Future<void> barrier) {
    if (identical(_pendingPauseBarrier, barrier)) {
      _pendingPauseBarrier = null;
    }
  }

  void recordFailedPause(Future<void> Function() pause) {
    _retryPause = pause;
  }

  void clearFailedPause(Future<void> Function() pause) {
    if (identical(_retryPause, pause)) _retryPause = null;
  }

  bool _isCurrent(VideoPlaybackReservation reservation) =>
      identical(_current, reservation) && _current!._token == reservation._token;

  void _release(VideoPlaybackReservation reservation) {
    if (!identical(_current, reservation)) return;
    _current = null;
  }
}

/// A unique permission granted by [VideoPlaybackArbiter].
final class VideoPlaybackReservation {
  VideoPlaybackReservation._(
    this._arbiter,
    this._owner,
    this._token,
    this._priorPauseBarrier,
    this._pauseSteps,
    this._pause,
  );

  final VideoPlaybackArbiter _arbiter;
  final Object _owner;
  final int _token;
  Future<void>? _priorPauseBarrier;
  List<Future<void> Function()> _pauseSteps;
  Future<void> Function()? _pause;
  Future<void> Function()? _failedPause;
  Future<void> Function()? _retriedPause;
  late final Future<void> _pauseBarrier;
  var _released = false;

  bool get isCurrent => !_released && _arbiter._isCurrent(this);

  int get debugRetainedPriorStateCount =>
      (_priorPauseBarrier == null ? 0 : 1) +
      (_pauseSteps.isEmpty ? 0 : 1) +
      (_retriedPause == null ? 0 : 1) +
      (_failedPause == null ? 0 : 1);

  /// Waits for all prior active owners to stop. Pause errors are delivered to
  /// the requester so it cannot start alongside an owner that failed to stop.
  Future<void> waitUntilReady() => _pauseBarrier;

  Future<void> _startPauseBarrier() {
    _pauseBarrier = _waitForPrevious();
    return _pauseBarrier;
  }

  Future<void> _waitForPrevious() async {
    try {
      await _priorPauseBarrier;
      for (final pause in _pauseSteps) {
        _retriedPause ??= pause;
        try {
          await pause();
        } catch (_) {
          _failedPause = pause;
          rethrow;
        }
      }
    } finally {
      _priorPauseBarrier = null;
      _pauseSteps = const <Future<void> Function()>[];
    }
  }

  Future<void> Function()? pauseForRetry() => _pause;

  void _clearCompletedPriorState() {
    _retriedPause = null;
    _failedPause = null;
  }

  void release() {
    if (_released) return;
    _released = true;
    _pause = null;
    _arbiter._release(this);
  }
}
