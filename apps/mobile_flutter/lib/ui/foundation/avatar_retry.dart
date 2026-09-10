import 'dart:async';

import 'package:flutter/widgets.dart';

/// Recovery remains possible during prolonged outages. Attempts are unbounded
/// over time, but each visible owner backs off to one/minute, and the shared
/// queue starts at most four retries/second. No credentials or URLs are kept.
final class AvatarRetry {
  static final _queue = _AvatarRetryQueue();
  static const _delays = [1, 2, 5, 15, 30, 60];
  VoidCallback? _callback;
  int _attempt = 0;
  int _ticks = 0;
  bool _active = true;

  void schedule(VoidCallback callback) {
    if (_callback != null) return;
    _callback = callback;
    _ticks = _delays[_attempt.clamp(0, _delays.length - 1)] * 4;
    if (_active) _queue.add(this);
  }

  void setActive(bool active) {
    if (_active == active) return;
    _active = active;
    if (active && _callback != null) {
      _queue.add(this);
    } else {
      _queue.remove(this);
    }
  }

  void reset() {
    _queue.remove(this);
    _callback = null;
    _attempt = 0;
  }

  void _run() {
    final callback = _callback;
    _callback = null;
    if (_attempt < _delays.length - 1) _attempt++;
    callback?.call();
  }
}

final class _AvatarRetryQueue with WidgetsBindingObserver {
  final _pending = <AvatarRetry>{};
  Timer? _timer;
  bool _observing = false;

  void add(AvatarRetry retry) {
    _pending.add(retry);
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    _start();
  }

  void remove(AvatarRetry retry) {
    _pending.remove(retry);
    if (_pending.isEmpty) {
      _timer?.cancel();
      _timer = null;
      if (_observing) WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
  }

  void _start() {
    final state = WidgetsBinding.instance.lifecycleState;
    if (_timer != null ||
        _pending.isEmpty ||
        (state != null && state != AppLifecycleState.resumed)) {
      return;
    }
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      AvatarRetry? due;
      for (final retry in _pending) {
        if (retry._ticks > 0) retry._ticks--;
        if (retry._ticks == 0) due ??= retry;
      }
      if (due != null) {
        remove(due);
        due._run();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _start();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }
}
