import 'dart:async';
import 'package:flutter/widgets.dart';

/// Cooperative gate: wait BETWEEN bounded chunks, outside database locks.
/// UI never awaits this gate. Background allows OS-permitted maintenance but
/// denies animations; interaction and memory pressure enforce a quiet interval.
final class MaintenanceActivity extends ChangeNotifier
    with WidgetsBindingObserver {
  MaintenanceActivity(
      {DateTime Function()? clock, Future<void> Function(Duration)? delay})
      : _clock = clock ?? DateTime.now,
        _delay = delay {
    _quietSince = _clock();
  }
  static final instance = MaintenanceActivity();
  static const idleInterval = Duration(milliseconds: 500);
  final DateTime Function() _clock;
  final Future<void> Function(Duration)? _delay;
  final _reasons = <String>{};
  late DateTime _quietSince;
  Completer<void> _changed = Completer<void>();
  Timer? _resumeTimer;
  int _generation = 0, _consumers = 0, _waiters = 0;
  int pressureEpoch = 0;
  MaintenanceLease? _heavyLease;
  final _heavyQueue = <Object>[];
  bool get heavyBusy => _heavyLease != null;
  bool _installed = false,
      _disposed = false,
      _idleReady = false,
      _isForeground = true,
      _delayPending = false;
  bool get canMaintain =>
      _reasons.isEmpty &&
      (_idleReady || _clock().difference(_quietSince) >= idleInterval);
  bool get interactive => _reasons.isNotEmpty;
  bool get isForeground => _isForeground;
  Set<String> get activeReasons => Set.unmodifiable(_reasons);
  @visibleForTesting
  int get pendingWaiters => _waiters;
  @visibleForTesting
  int get registeredConsumers => _consumers;
  void install() {
    if (_installed) return;
    _installed = true;
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _isForeground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _consumers++;
    _armIdle();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (_consumers > 0) _consumers--;
    _cancelIfUnused();
  }

  void _cancelIfUnused() {
    if (_consumers == 0 && _waiters == 0) {
      _resumeTimer?.cancel();
      _resumeTimer = null;
      _generation++;
      _delayPending = false;
    }
  }

  void setInteractive(String reason, bool active) {
    if (_disposed) return;
    if (!(active ? _reasons.add(reason) : _reasons.remove(reason))) return;
    _quietSince = _clock();
    _idleReady = false;
    _signal();
  }

  void pulse(String reason) {
    setInteractive(reason, true);
    setInteractive(reason, false);
  }

  void pressure() {
    if (_disposed) return;
    pressureEpoch++;
    _quietSince = _clock();
    _idleReady = false;
    _signal();
  }

  void _signal() {
    if (_disposed) return;
    _generation++;
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _delayPending = false;
    if (!_changed.isCompleted) _changed.complete();
    _changed = Completer<void>();
    notifyListeners();
    _armIdle();
  }

  void _armIdle() {
    if (_resumeTimer != null ||
        _delayPending ||
        _disposed ||
        canMaintain ||
        _reasons.isNotEmpty ||
        (_consumers == 0 && _waiters == 0)) {
      return;
    }
    final generation = _generation;
    final remaining = idleInterval - _clock().difference(_quietSince);
    void ready() {
      if (_disposed || generation != _generation) return;
      _resumeTimer = null;
      _delayPending = false;
      _idleReady = true;
      if (!_changed.isCompleted) _changed.complete();
      _changed = Completer<void>();
      notifyListeners();
    }

    final delay = _delay;
    if (delay != null) {
      _delayPending = true;
      unawaited(delay(remaining).then((_) => ready()));
    } else {
      _resumeTimer = Timer(remaining, ready);
    }
  }

  Future<void> waitForIdle(
      {Future<void>? cancelled, MaintenanceLease? lease}) async {
    _waiters++;
    var stopped = false;
    final cancellation = cancelled?.then((_) {
      stopped = true;
    });
    try {
      while (!_disposed &&
          !stopped &&
          (!canMaintain ||
              (_heavyLease != null && !identical(_heavyLease, lease)))) {
        _armIdle();
        if (cancellation == null) {
          await _changed.future;
        } else {
          await Future.any([_changed.future, cancellation]);
        }
      }
    } finally {
      _waiters--;
      _cancelIfUnused();
    }
  }

  /// FIFO exclusive lease. UI/idle eligibility remains separate so a native
  /// lease owner can subscribe to canMaintain without blocking itself.
  Future<MaintenanceLease?> acquireHeavy(
      {bool Function()? cancelled, Future<void>? cancellation}) async {
    final ticket = Object();
    _heavyQueue.add(ticket);
    final localCancel = Completer<void>();
    Timer? poll;
    bool stopped = false;
    if (cancelled != null) {
      if (cancelled()) {
        localCancel.complete();
      } else {
        poll = Timer.periodic(const Duration(milliseconds: 25), (_) {
          if (cancelled() && !localCancel.isCompleted) localCancel.complete();
        });
      }
    }
    final signal = Future.any<void>(
        [localCancel.future, if (cancellation != null) cancellation]).then((_) {
      stopped = true;
    });
    try {
      while (!_disposed && !stopped && !(cancelled?.call() ?? false)) {
        await waitForIdle(cancelled: signal);
        if (_disposed || stopped || (cancelled?.call() ?? false)) return null;
        if (_heavyLease == null &&
            canMaintain &&
            identical(_heavyQueue.first, ticket)) {
          final lease = MaintenanceLease._(this);
          _heavyLease = lease;
          _signal();
          return lease;
        }
        await Future.any<void>([_changed.future, signal]);
      }
      return null;
    } finally {
      poll?.cancel();
      _heavyQueue.remove(ticket);
      _signal();
    }
  }

  void _releaseHeavy(MaintenanceLease lease) {
    if (!identical(_heavyLease, lease)) return;
    _heavyLease = null;
    _signal();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _isForeground) return;
    _isForeground = foreground;
    notifyListeners();
  }

  @override
  void didHaveMemoryPressure() => pressure();
  @visibleForTesting
  void resetForTesting() {
    _generation++;
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _delayPending = false;
    _reasons.clear();
    _idleReady = true;
    _isForeground = true;
    if (_installed) WidgetsBinding.instance.removeObserver(this);
    _installed = false;
    if (!_changed.isCompleted) _changed.complete();
    _changed = Completer<void>();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _resumeTimer?.cancel();
    if (_installed) WidgetsBinding.instance.removeObserver(this);
    if (!_changed.isCompleted) _changed.complete();
    super.dispose();
  }
}

final class MaintenanceLease {
  MaintenanceLease._(this._owner);
  final MaintenanceActivity _owner;
  bool _released = false;
  void release() {
    if (_released) return;
    _released = true;
    _owner._releaseHeavy(this);
  }

  void dispose() => release();
}
