import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/notification/notification_diagnostics.dart';
import 'push_token_provider.dart';

/// 个推 Token（CID）提供方。
///
/// 隐私门槛（构造前由组合根检查，本类不重复判断）：
/// 1. 仅 Android；
/// 2. 用户已持久化同意隐私政策（PrivacyConsentStore）——同意前 SDK 只
///    处于 preInit 状态（无采集无联网）；
/// 3. 未同意/初始化失败 → token 为 null，不注册 pusher，聊天不受影响。
///
/// CID 即 Matrix pusher 的 pushkey（设备级绑定；登出=删 pusher，
/// 绝不做手机号/用户名 alias）。
final class GetuiPushTokenProvider implements PushTokenProvider {
  GetuiPushTokenProvider({NotificationDiagnostics? diagnostics})
      : diagnostics = diagnostics ?? NotificationDiagnostics.shared;

  static const _methodChannel = MethodChannel('chatflow/getui');
  static const _eventChannel = EventChannel('chatflow/getui/events');

  final NotificationDiagnostics diagnostics;
  bool _initialized = false;
  StreamSubscription<dynamic>? _events;

  /// 第二段初始化（preInit 已在 Application 完成且无需同意）。
  /// 必须在持久化同意之后调用。
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final ok = await _methodChannel.invokeMethod<bool>('initialize');
      diagnostics.record(
          NotificationDiagStage.push, 'getui initialize: ${ok == true}');
    } catch (error) {
      diagnostics.record(NotificationDiagStage.push,
          'getui initialize failed: ${error.runtimeType}');
    }
  }

  @override
  Future<String?> token() async {
    if (!_initialized) return null;
    try {
      final cid = await _methodChannel.invokeMethod<String>('getCid');
      return (cid == null || cid.isEmpty) ? null : cid;
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<String?> tokenUpdates() => _eventChannel.receiveBroadcastStream().map(
        (event) {
          if (event is Map && event['type'] == 'cid') {
            final cid = event['cid'];
            return cid is String && cid.isNotEmpty ? cid : null;
          }
          return null;
        },
      ).where((cid) => cid != null);

  @override
  Future<void> dispose() async {
    await _events?.cancel();
    _events = null;
  }
}
