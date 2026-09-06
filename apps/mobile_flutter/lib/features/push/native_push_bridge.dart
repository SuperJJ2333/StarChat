import 'dart:async';

import 'package:flutter/services.dart';

/// 规格：NativePushBridge（Flutter 侧）——接收 Android 推送事件并分发。
///
/// - pushMessage：经 NotificationCoordinator 落系统通知（通用文案，无业务
///   内容——详细通知仍由 Matrix 同步路径产出；此事件用于唤醒/兜底）。
/// - friendRequest：刷新桌面角标（BadgeService）+ 好友申请红点。
/// MethodChannel 名与 Native 侧一致（chatflow/push）。
final class NativePushBridge {
  NativePushBridge({
    required this.onPushMessage,
    required this.onFriendRequest,
  });

  /// pushMessage 事件（消息唤醒：通知协调器显示通用通知）。
  final Future<void> Function() onPushMessage;

  /// friendRequest 事件（角标 + 好友红点）。
  final Future<void> Function() onFriendRequest;

  static const channel = MethodChannel('chatflow/push');

  MethodChannel? _installed;
  static NativePushBridge? _owner;

  /// 组合根装配：返回可卸载句柄。
  Future<void> install() async {
    _installed = channel;
    _owner = this;
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'pushMessage':
          await onPushMessage();
        case 'friendRequest':
          await onFriendRequest();
        default:
          return false;
      }
      return true;
    });
    try {
      // Register the Dart callback before asking Android to replay cold wakes.
      await channel.invokeMethod<void>('pushListenerReady');
    } on MissingPluginException {
      // Other platforms and older native hosts do not have a pending queue.
    }
  }

  Future<void> uninstall() async {
    if (identical(_owner, this) && identical(_installed, channel)) {
      // Remove the listener synchronously so late disposal cannot detach a
      // replacement session after awaiting the native handshake.
      _owner = null;
      channel.setMethodCallHandler(null);
      try {
        await channel.invokeMethod<void>('pushListenerStopped');
      } on MissingPluginException {
        // No Android queue on this host.
      }
    }
    _installed = null;
  }
}
