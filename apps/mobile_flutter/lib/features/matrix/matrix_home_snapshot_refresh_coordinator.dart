import 'dart:async';

final class _SnapshotRefreshWork<T> {
  const _SnapshotRefreshWork(this.loader, this.onValue);
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
  _SnapshotRefreshWork<T>? _pending;
  var _running = false;
  var _startScheduled = false;
  var _requested = 0;
  final Map<int, List<Completer<void>>> _waiters = {};

  Future<void> request(Future<T> Function() loader,
      {required void Function(T value) onValue}) {
    final request = ++_requested;
    final completer = Completer<void>();
    (_waiters[request] ??= []).add(completer);
    _pending = _SnapshotRefreshWork(loader, onValue);
    if (!_running && !_startScheduled) {
      _startScheduled = true;
      scheduleMicrotask(_start);
    }
    return completer.future;
  }

  void _start() {
    _startScheduled = false;
    final work = _pending;
    if (work == null || _running) return;
    _running = true;
    unawaited(_drain(work));
  }

  Future<void> _drain(_SnapshotRefreshWork<T> work) async {
    try {
      while (true) {
        final completedThrough = _requested;
        _pending = null;
        try {
          final value = await Future<T>.sync(work.loader);
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
      if (_pending != null && !_startScheduled) {
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
