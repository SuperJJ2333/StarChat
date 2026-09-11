import 'dart:async';

import 'package:wakelock_plus/wakelock_plus.dart';

/// Owns process-wide screen-on requests without allowing one feature to turn
/// the screen off while another feature is still active.
final class ScreenOnLeaseCoordinator {
  ScreenOnLeaseCoordinator(this._setScreenOn);

  final Future<void> Function(bool enabled) _setScreenOn;
  final Set<int> _owners = <int>{};
  int _nextToken = 0;
  int _revision = 0;
  bool _running = false;
  Completer<void>? _idle;

  /// Completes once the current desired state has been sent to the platform.
  Future<void> get settled => _idle?.future ?? Future<void>.value();

  ScreenOnLease acquire() {
    final token = ++_nextToken;
    _owners.add(token);
    _requestDrain();
    return ScreenOnLease._(this, token);
  }

  void _release(int token) {
    if (!_owners.remove(token)) return;
    _requestDrain();
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
        try {
          await _setScreenOn(_owners.isNotEmpty);
        } catch (_) {
          // A platform error must not prevent a later ownership change.
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

/// A single idempotent owner of a [ScreenOnLeaseCoordinator].
final class ScreenOnLease {
  ScreenOnLease._(this._coordinator, this._token);

  final ScreenOnLeaseCoordinator _coordinator;
  final int _token;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _coordinator._release(_token);
  }
}

/// Converts an enabled/disabled callback into one stable screen-on owner.
final class ScreenOnDemand {
  ScreenOnDemand(this._coordinator);

  final ScreenOnLeaseCoordinator _coordinator;
  ScreenOnLease? _lease;

  Future<void> setEnabled(bool enabled) {
    if (enabled) {
      _lease ??= _coordinator.acquire();
    } else {
      _lease?.release();
      _lease = null;
    }
    return _coordinator.settled;
  }
}

/// The application-wide platform owner used by calls and video playback.
final screenOnLeaseCoordinator = ScreenOnLeaseCoordinator(
    (enabled) => WakelockPlus.toggle(enable: enabled));
