import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/notification/notification_diagnostics.dart';
import 'push_tap_router.dart';
import 'push_token_provider.dart';

/// Direct APNs device tokens for the Sygnal APNs pushkin (never FCM tokens).
final class NativeApnsPushTokenProvider implements PushTokenProvider {
  NativeApnsPushTokenProvider({
    MethodChannel channel = const MethodChannel('chatflow/apns'),
    required this.onTap,
  }) : _channel = channel;

  final MethodChannel _channel;
  final void Function(PushNotificationPayload payload) onTap;
  final _updates = StreamController<String?>.broadcast();
  bool _started = false;
  bool _disposed = false;

  static bool _validToken(Object? value) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= 512 &&
      value.length.isEven &&
      RegExp(r'^[a-fA-F0-9]+$').hasMatch(value);

  Future<void> initialize() async {
    if (_started || _disposed) return;
    _channel.setMethodCallHandler(_handleCall);
    try {
      await _channel.invokeMethod<void>('start');
      if (!_disposed) _started = true;
    } on PlatformException {
      _recordUnavailable();
    } on MissingPluginException {
      _recordUnavailable();
    }
  }

  Future<Object?> _handleCall(MethodCall call) async {
    if (_disposed) return false;
    switch (call.method) {
      case 'tokenChanged':
        if (_validToken(call.arguments)) _updates.add(call.arguments as String);
        return true;
      case 'notificationTap':
        if (call.arguments is! Map) return false;
        onTap(PushNotificationPayload.parse(
            Map<Object?, Object?>.from(call.arguments as Map)));
        return true;
      default:
        return false;
    }
  }

  void _recordUnavailable() => NotificationDiagnostics.shared
      .record(NotificationDiagStage.push, 'native APNs bridge unavailable');

  @override
  Future<String?> token() async {
    if (_disposed) return null;
    await initialize();
    if (!_started) return null;
    try {
      final value = await _channel.invokeMethod<Object?>('getToken');
      return _validToken(value) ? value as String : null;
    } on PlatformException {
      _recordUnavailable();
    } on MissingPluginException {
      _recordUnavailable();
    }
    return null;
  }

  @override
  Stream<String?> tokenUpdates() => _updates.stream;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _channel.setMethodCallHandler(null);
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      _recordUnavailable();
    } on MissingPluginException {
      // A build without the bridge has nothing native to stop.
    }
    await _updates.close();
  }
}
