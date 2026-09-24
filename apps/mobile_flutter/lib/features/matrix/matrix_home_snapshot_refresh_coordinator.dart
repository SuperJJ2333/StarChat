import 'dart:async';

final class _SnapshotRefreshWork<T> {
  const _SnapshotRefreshWork(this.loader, this.onValue, this.immediate);
  final bool immediate;
  final Future<T> Function() loader;
  final void Function(T value) onValue;
}

/// Serializes conversation snapshot work while retaining one latest follow-up
/// pass for requests received during an active load.
///
/// Requests made in the same event-loop turn share the initial pass. The
/// coordinator exposes failures to every affected caller; the page decides
/// whether that failure is best-effort presentation work.
final class SnapshotRefreshCoordinator<T> {
  SnapshotRefreshCoordinator({this.coalesceWindow = Duration.zero});
  final Duration coalesceWindow;
  bool _paused = false, _disposed = false;
  Completer<void>? _resume;
  Timer? _delayTimer;
  Completer<void>? _delay;

  void setPaused(bool paused) {
    if (_disposed || _paused == paused) return;
    _paused = paused;
    if (!paused) {
      _resume?.complete();
      _resume = null;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pending = null;
    _delayTimer?.cancel();
    _delayTimer = null;
    _delay?.complete();
    _delay = null;
    _resume?.complete();
    _resume = null;
    _completeThrough(_requested);
  }

  Future<void> _waitForWindow() async {
    if (coalesceWindow == Duration.zero) return;
    final done = _delay = Completer<void>();
    _delayTimer = Timer(coalesceWindow, () {
      _delayTimer = null;
      _delay = null;
      done.complete();
    });
    await done.future;
  }

  Future<void> _waitUntilResumed() async {
    while (_paused && !_disposed) {
      await (_resume ??= Completer<void>()).future;
    }
  }

  _SnapshotRefreshWork<T>? _pending;
  var _running = false;
  var _startScheduled = false;
  var _requested = 0;
  final Map<int, List<Completer<void>>> _waiters = {};

  Future<void> request(Future<T> Function() loader,
      {required void Function(T value) onValue, bool immediate = false}) {
    if (_disposed) return Future.value();
    final request = ++_requested;
    final completer = Completer<void>();
    (_waiters[request] ??= []).add(completer);
    _pending = _SnapshotRefreshWork(loader, onValue, immediate);
    if (!_running && !_startScheduled) {
      _startScheduled = true;
      scheduleMicrotask(_start);
    }
    return completer.future;
  }

  void _start() {
    _startScheduled = false;
    final work = _pending;
    if (work == null || _running || _disposed) return;
    _running = true;
    unawaited(_drain(work));
  }

  Future<void> _drain(_SnapshotRefreshWork<T> work) async {
    try {
      while (!_disposed) {
        if (_paused) await _waitUntilResumed();
        if (coalesceWindow != Duration.zero && !(_pending ?? work).immediate) {
          await _waitForWindow();
        }
        if (_paused) await _waitUntilResumed();
        if (_disposed) return;
        work = _pending ?? work;
        final completedThrough = _requested;
        _pending = null;
        try {
          final value = await Future<T>.sync(work.loader);
          final held = _paused;
          if (held) await _waitUntilResumed();
          if (_disposed) return;
          // A newer request received during a transition supersedes this result.
          if (held && _pending != null) {
            work = _pending!;
            continue;
          }
          work.onValue(value);
          _completeThrough(completedThrough);
        } catch (error, stackTrace) {
          _completeThroughError(completedThrough, error, stackTrace);
        }
        final next = _pending;
        if (next == null) return;
        work = next;
      }
    } finally {
      _running = false;
      if (!_disposed && _pending != null && !_startScheduled) {
        _startScheduled = true;
        scheduleMicrotask(_start);
      }
    }
  }

  void _completeThrough(int completedThrough) {
    final completed = _waiters.keys
        .where((request) => request <= completedThrough)
        .toList(growable: false);
    for (final request in completed) {
      for (final waiter in _waiters.remove(request)!) {
        waiter.complete();
      }
    }
  }

  void _completeThroughError(
      int completedThrough, Object error, StackTrace stackTrace) {
    final completed = _waiters.keys
        .where((request) => request <= completedThrough)
        .toList(growable: false);
    for (final request in completed) {
      for (final waiter in _waiters.remove(request)!) {
        waiter.completeError(error, stackTrace);
      }
    }
  }
}
