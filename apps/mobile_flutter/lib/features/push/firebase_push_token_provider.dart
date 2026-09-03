import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../../core/notification/notification_diagnostics.dart';
import 'push_token_provider.dart';

/// FCM Token 提供方。
///
/// 安全降级：FirebaseApp 初始化失败（未放置 google-services.json、
/// 平台不支持、无 Google Play 服务）时 token 恒为 null 并记录诊断，
/// 绝不抛出——推送是增强通道，Matrix 同步通道始终独立工作。
final class FirebasePushTokenProvider implements PushTokenProvider {
  FirebasePushTokenProvider._(this._messaging, this._diagnostics);

  final FirebaseMessaging _messaging;
  final NotificationDiagnostics _diagnostics;

  /// 尝试初始化 Firebase；不可用返回 null（组合根降级为 Noop）。
  static Future<FirebasePushTokenProvider?> tryCreate({
    NotificationDiagnostics? diagnostics,
  }) async {
    final diag = diagnostics ?? NotificationDiagnostics.shared;
    try {
      await Firebase.initializeApp();
      return FirebasePushTokenProvider._(
        FirebaseMessaging.instance,
        diag,
      );
    } catch (error) {
      diag.record(NotificationDiagStage.push,
          'firebase unavailable: ${error.runtimeType}');
      return null;
    }
  }

  @override
  Future<String?> token() async {
    try {
      return await _messaging.getToken();
    } catch (error) {
      _diagnostics.record(
          NotificationDiagStage.push, 'get token failed: ${error.runtimeType}');
      return null;
    }
  }

  @override
  Stream<String?> tokenUpdates() => _messaging.onTokenRefresh
          .map<String?>((token) => token)
          .handleError((Object error) {
        _diagnostics.record(NotificationDiagStage.push,
            'token refresh stream error: ${error.runtimeType}');
      });

  @override
  Future<void> dispose() async {}
}
