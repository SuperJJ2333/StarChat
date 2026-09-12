import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show setEquals;

enum MatrixConnectionStatus {
  unknown,
  connecting,
  offline,
  connected,
  serviceUnavailable,
}

enum MatrixTransport { wifi, mobile, ethernet, vpn, bluetooth, other }

abstract interface class MatrixTransportMonitor {
  Future<Set<MatrixTransport>> check();
  Stream<Set<MatrixTransport>> get changes;
}

final class ConnectivityPlusTransportMonitor implements MatrixTransportMonitor {
  ConnectivityPlusTransportMonitor([Connectivity? connectivity])
      : _connectivity = connectivity ?? Connectivity();
  final Connectivity _connectivity;

  Set<MatrixTransport> _map(Iterable<ConnectivityResult> values) => values
      .where((value) => value != ConnectivityResult.none)
      .map((value) => switch (value) {
            ConnectivityResult.wifi => MatrixTransport.wifi,
            ConnectivityResult.mobile => MatrixTransport.mobile,
            ConnectivityResult.ethernet => MatrixTransport.ethernet,
            ConnectivityResult.vpn => MatrixTransport.vpn,
            ConnectivityResult.bluetooth => MatrixTransport.bluetooth,
            _ => MatrixTransport.other,
          })
      .toSet();
  @override
  Future<Set<MatrixTransport>> check() async =>
      _map(await _connectivity.checkConnectivity());
  @override
  Stream<Set<MatrixTransport>> get changes =>
      _connectivity.onConnectivityChanged.map(_map);
}

/// Owns one session's transport subscription. Transport is only a recovery
/// candidate: callers must wait for the Matrix SDK's finished status.
final class MatrixSyncRecoveryController {
  MatrixSyncRecoveryController({
    required this.transport,
    required this.onCandidate,
    required this.onOffline,
    this.onTransportStateChanged,
  });
  final MatrixTransportMonitor transport;
  final Future<void> Function(bool forceRestart) onCandidate;
  final void Function() onOffline;
  final void Function(bool online)? onTransportStateChanged;
  StreamSubscription<Set<MatrixTransport>>? _subscription;
  Set<MatrixTransport>? _last;
  Future<void>? _softDispatching;
  Future<void>? _forceDispatching;
  bool _forcePending = false;
  int _revision = 0;
  bool _disposed = false;

  void start() {
    if (_disposed || _subscription != null) return;
    _subscription = transport.changes.listen(_onChange, onError: (_, __) {});
    unawaited(_check(forceRestart: false));
  }

  void onAppResumed() {
    if (!_disposed) unawaited(_check(forceRestart: true));
  }

  /// Re-checks transport and awaits the recovery selected for this session.
  /// This is deliberately awaitable for the product retry action: a caller
  /// must not re-enable retry while an SDK abort/replacement is still pending.
  Future<void> retry() => _check(forceRestart: true);

  Future<void> _check({required bool forceRestart}) async {
    final revision = ++_revision;
    try {
      final value = await transport.check();
      if (_disposed || revision != _revision) return;
      await _onTransport(value, forceRestart: forceRestart);
    } catch (_) {}
  }

  void _onChange(Set<MatrixTransport> value) {
    _revision++;
    unawaited(_onTransport(value, forceRestart: false));
  }

  Future<void> _onTransport(Set<MatrixTransport> value,
      {required bool forceRestart}) {
    if (_disposed) return Future.value();
    final previous = _last;
    _last = value.toSet();
    onTransportStateChanged?.call(value.isNotEmpty);
    if (value.isEmpty) {
      _forcePending = false;
      onOffline();
      return Future.value();
    }
    final changed = previous != null && !setEquals(previous, value);
    final resumedTransport = previous?.isEmpty ?? false;
    if (previous == null || resumedTransport || forceRestart || changed) {
      return _dispatch(forceRestart || resumedTransport || changed);
    }
    return Future.value();
  }

  Future<void> _dispatch(bool forceRestart) {
    if (_disposed) return Future.value();
    if (forceRestart) {
      final existing = _forceDispatching;
      if (existing != null) {
        _forcePending = true;
        return existing;
      }
      return _startForceDispatch();
    }
    final soft = _softDispatching;
    if (soft != null) return soft;
    final force = _forceDispatching;
    if (force != null) return force;
    return _startSoftDispatch();
  }

  Future<void> _startSoftDispatch() {
    late final Future<void> dispatch;
    dispatch = onCandidate(false).catchError((_) {}).whenComplete(() {
      if (identical(_softDispatching, dispatch)) _softDispatching = null;
    });
    _softDispatching = dispatch;
    return dispatch;
  }

  Future<void> _startForceDispatch() {
    late final Future<void> dispatch;
    dispatch = onCandidate(true).catchError((_) {}).whenComplete(() {
      if (!identical(_forceDispatching, dispatch)) return;
      _forceDispatching = null;
      if (_forcePending && !_disposed) {
        _forcePending = false;
        unawaited(_startForceDispatch());
      }
    });
    _forceDispatching = dispatch;
    return dispatch;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
  }
}
