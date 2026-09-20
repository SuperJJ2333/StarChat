import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

enum CallPermissionAction {
  microphone,
  camera,
  notifications,
  callChannel,
  ongoingChannel,
  fullScreen,
  overlay,
  appSettings,
}

/// null means the operating system could not report the state, never granted.
final class CallPermissionReadiness {
  const CallPermissionReadiness(
      {this.android = false,
      this.microphone,
      this.camera,
      this.notifications,
      this.callChannel,
      this.ongoingChannel,
      this.fullScreenRequired = false,
      this.fullScreen,
      this.overlay});
  final bool android;
  final bool? microphone, camera, notifications, callChannel, ongoingChannel;
  final bool fullScreenRequired;
  final bool? fullScreen, overlay;

  /// 与上一次已知状态合并：**非空值优先，不可知（null）时保留上一次的值**。
  ///
  /// 平台查询失败或不可用时会返回 null 字段；整体替换会把已经显示过的
  /// 「已开启 / 未开启」降级成「待检查」（微信级加载模型 L4：失败不覆盖）。
  /// `android` 与 `fullScreenRequired` 是设备事实，一旦为真就保持为真。
  CallPermissionReadiness mergedWith(CallPermissionReadiness? previous) {
    if (previous == null) return this;
    return CallPermissionReadiness(
      android: android || previous.android,
      microphone: microphone ?? previous.microphone,
      camera: camera ?? previous.camera,
      notifications: notifications ?? previous.notifications,
      callChannel: callChannel ?? previous.callChannel,
      ongoingChannel: ongoingChannel ?? previous.ongoingChannel,
      fullScreenRequired: fullScreenRequired || previous.fullScreenRequired,
      fullScreen: fullScreen ?? previous.fullScreen,
      overlay: overlay ?? previous.overlay,
    );
  }
}

abstract interface class CallPermissionReadinessGateway {
  Future<CallPermissionReadiness> read();
  Future<bool> act(CallPermissionAction action);
}

final class SystemCallPermissionReadinessGateway
    implements CallPermissionReadinessGateway {
  const SystemCallPermissionReadinessGateway();
  static const _channel = MethodChannel('chatflow/notification');

  @override
  Future<CallPermissionReadiness> read() async {
    try {
      final state = await _channel
          .invokeMapMethod<String, dynamic>('getCallPermissionReadiness');
      if (state != null) {
        return CallPermissionReadiness(
          android: state['android'] == true,
          microphone: state['microphone'] as bool?,
          camera: state['camera'] as bool?,
          notifications: state['notifications'] as bool?,
          callChannel: state['callChannel'] as bool?,
          ongoingChannel: state['ongoingChannel'] as bool?,
          fullScreenRequired: state['fullScreenRequired'] == true,
          fullScreen: state['fullScreen'] as bool?,
          overlay: state['overlay'] as bool?,
        );
      }
    } catch (_) {/* Other platforms use their own permission service. */}
    Future<bool?> status(Permission permission) async {
      try {
        return (await permission.status).isGranted;
      } catch (_) {
        return null;
      }
    }

    return CallPermissionReadiness(
      microphone: await status(Permission.microphone),
      camera: await status(Permission.camera),
      notifications: await status(Permission.notification),
    );
  }

  /// Invoked only by a user's tap, never by read() or lifecycle refresh.
  @override
  Future<bool> act(CallPermissionAction action) async {
    try {
      final permission = switch (action) {
        CallPermissionAction.microphone => Permission.microphone,
        CallPermissionAction.camera => Permission.camera,
        CallPermissionAction.notifications => Permission.notification,
        _ => null,
      };
      if (permission != null) {
        final current = await permission.status;
        if (current.isPermanentlyDenied ||
            current.isRestricted ||
            current.isGranted) {
          if (action == CallPermissionAction.notifications) {
            return _open('openNotificationSettings');
          }
          return openAppSettings();
        }
        final requested = await permission.request();
        if (!requested.isGranted &&
            action == CallPermissionAction.notifications) {
          return _open('openNotificationSettings');
        }
        if (requested.isPermanentlyDenied) {
          return openAppSettings();
        }
        return requested.isGranted;
      }
      return switch (action) {
        CallPermissionAction.callChannel =>
          _open('openChannelSettings', {'channelId': 'calls_ring'}),
        CallPermissionAction.ongoingChannel =>
          _open('openChannelSettings', {'channelId': 'chatflow_silent'}),
        CallPermissionAction.fullScreen => _open('openFullScreenSettings'),
        CallPermissionAction.overlay => _open('openOverlaySettings'),
        _ => openAppSettings(),
      };
    } catch (_) {
      return false;
    }
  }

  Future<bool> _open(String method, [Map<String, String>? arguments]) async {
    try {
      if (await _channel.invokeMethod<bool>(method, arguments) == true) {
        return true;
      }
    } catch (_) {/* Fall back to the app's system settings. */}
    return openAppSettings();
  }
}
