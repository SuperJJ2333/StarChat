import 'dart:async';

import 'package:flutter/foundation.dart';

enum AppConnectionStatus {
  unknown,
  connecting,
  offline,
  connected,
  serviceUnavailable,
}

/// Product-level connectivity state. It intentionally knows nothing about
/// Matrix, HTTP, accounts, or business operations.
final class AppConnectionStatusHub {
  AppConnectionStatusHub._();
  static final shared = AppConnectionStatusHub._();

  final _status = ValueNotifier(AppConnectionStatus.unknown);
  ValueListenable<AppConnectionStatus> get status => _status;
  Object? _owner;
  VoidCallback? _removeListener;
  Future<void> Function()? _retry;
  Future<void>? _retryFlight;

  void bind<T>(Object owner, ValueListenable<T> source,
      AppConnectionStatus Function(T) map,
      {Future<void> Function()? onRetry}) {
    _removeListener?.call();
    _retryFlight = null;
    _owner = owner;
    _retry = onRetry;
    void update() {
      if (identical(_owner, owner)) _status.value = map(source.value);
    }

    source.addListener(update);
    _removeListener = () => source.removeListener(update);
    update();
  }

  void unbind(Object owner) {
    if (!identical(_owner, owner)) return;
    _removeListener?.call();
    _removeListener = null;
    _owner = null;
    _retry = null;
    _retryFlight = null;
    _status.value = AppConnectionStatus.unknown;
  }

  Future<void> retry() {
    final retry = _retry;
    if (retry == null) return Future.value();
    final existing = _retryFlight;
    if (existing != null) return existing;
    late final Future<void> flight;
    flight = Future.sync(retry).whenComplete(() {
      if (identical(_retryFlight, flight)) _retryFlight = null;
    });
    _retryFlight = flight;
    return flight;
  }
}
