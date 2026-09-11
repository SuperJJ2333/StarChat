import 'package:flutter/foundation.dart';

/// Grants a bounded number of media animations to eligible owners.
final class MediaAnimationBudget {
  MediaAnimationBudget({this.maxActive = 2}) {
    if (maxActive <= 0) throw ArgumentError.value(maxActive, 'maxActive');
  }

  final int maxActive;
  final _entries = <_MediaActivityToken>[];
  var _nextSequence = 0;
  var _recomputing = false;
  var _dirty = false;

  MediaActivityToken register({required int priority, bool eligible = true}) {
    final token =
        _MediaActivityToken(this, priority, eligible, _nextSequence++);
    _entries.add(token);
    _recompute();
    return token;
  }

  void _remove(_MediaActivityToken token) {
    _entries.remove(token);
    _recompute();
  }

  void _recompute() {
    if (_recomputing) {
      _dirty = true;
      return;
    }
    do {
      _dirty = false;
      _recomputing = true;
      try {
        final snapshot = List<_MediaActivityToken>.of(_entries);
        final active =
            snapshot.where((e) => e._eligible && !e._disposed).toList()
              ..sort((a, b) {
                final p = b._priority.compareTo(a._priority);
                return p != 0 ? p : a._sequence.compareTo(b._sequence);
              });
        final winners = active.take(maxActive).toSet();
        for (final entry in snapshot) {
          if (!winners.contains(entry)) entry._setGranted(false);
        }
        if (_dirty) continue;
        for (final entry in snapshot) {
          if (_dirty) break;
          if (winners.contains(entry) &&
              _entries.contains(entry) &&
              entry._eligible &&
              !entry._disposed) {
            entry._setGranted(true);
          }
        }
      } finally {
        _recomputing = false;
      }
    } while (_dirty);
  }
}

abstract interface class MediaActivityToken {
  ValueListenable<bool> get granted;
  void update({int? priority, bool? eligible});
  void dispose();
}

final class _MediaActivityToken implements MediaActivityToken {
  _MediaActivityToken(
      this._budget, this._priority, this._eligible, this._sequence);
  final MediaAnimationBudget _budget;
  final _granted = ValueNotifier(false);
  int _priority;
  bool _eligible;
  final int _sequence;
  var _disposed = false;
  var _notificationDepth = 0;
  var _disposePending = false;
  var _notifierDisposed = false;

  @override
  ValueListenable<bool> get granted => _granted;
  @override
  void update({int? priority, bool? eligible}) {
    if (_disposed) return;
    final nextPriority = priority ?? _priority;
    final nextEligible = eligible ?? _eligible;
    if (nextPriority == _priority && nextEligible == _eligible) return;
    _priority = nextPriority;
    _eligible = nextEligible;
    _budget._recompute();
  }

  void _setGranted(bool value) {
    if ((_disposed && value) || _granted.value == value) return;
    _notificationDepth++;
    try {
      _granted.value = value;
    } finally {
      _notificationDepth--;
      if (_notificationDepth == 0 && _disposePending) _disposeNotifier();
    }
  }

  void _disposeNotifier() {
    if (_notifierDisposed) return;
    _notifierDisposed = true;
    _granted.dispose();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _setGranted(false);
    _budget._remove(this);
    if (_notificationDepth == 0) {
      _disposeNotifier();
    } else {
      _disposePending = true;
    }
  }
}
