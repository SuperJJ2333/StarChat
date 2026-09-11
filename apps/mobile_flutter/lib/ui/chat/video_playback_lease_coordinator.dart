import 'dart:async';

/// Serializes process-wide wakelock ownership for full-screen video pages.
final class VideoPlaybackLeaseCoordinator {
  VideoPlaybackLeaseCoordinator(this._setWakelock);

  final Future<void> Function(bool enabled) _setWakelock;
  int _nextToken = 0;
  int? _current;
  var _revision = 0;
  var _running = false;
  var _disposed = false;
  Completer<void>? _idle;

  int? get current => _current;

  /// Completes when this coordinator has applied its current desired state.
  Future<void> get settled => _idle?.future ?? Future<void>.value();

  int acquire() {
    if (_disposed) throw StateError('Video playback coordinator is disposed');
    final token = ++_nextToken;
    _current = token;
    _requestDrain();
    return token;
  }

  void revoke(int token) {
    if (_current != token) return;
    _current = null;
    _requestDrain();
  }

  Future<void> dispose() {
    _disposed = true;
    _current = null;
    _requestDrain();
    return settled;
  }

  void _requestDrain() {
    _revision++;
    if (_running) return;
    _running = true;
    _idle = Completer<void>();
    unawaited(_drain());
  }

  Future<void> _drain() async {
    try {
      while (true) {
        final revision = _revision;
        final enabled = _current != null;
        try {
          await _setWakelock(enabled);
        } catch (_) {
          // A platform failure must not strand a later desired-state change.
        }
        if (revision == _revision) return;
      }
    } finally {
      _running = false;
      final idle = _idle;
      _idle = null;
      if (idle != null && !idle.isCompleted) idle.complete();
    }
  }
}
