import 'package:shared_preferences/shared_preferences.dart';

/// 通知埋点（PRD §63）：仅本地聚合计数，不记录任何消息正文、会话
/// 或发送者标识。接入远端分析设施属于后续阶段。
abstract interface class NotificationUsageRecorder {
  Future<void> count(String event);
}

final class SharedPreferencesNotificationUsageRecorder
    implements NotificationUsageRecorder {
  const SharedPreferencesNotificationUsageRecorder();

  static const _prefix = 'notification.metrics.';

  @override
  Future<void> count(String event) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        '$_prefix$event',
        (prefs.getInt('$_prefix$event') ?? 0) + 1,
      );
    } catch (_) {
      // 埋点失败静默。
    }
  }
}

/// PRD §63 定义的事件名。
abstract final class NotificationUsageEvents {
  static const received = 'notification_received';
  static const displayed = 'notification_displayed';
  static const opened = 'notification_opened';
  static const permissionPrompted = 'notification_permission_prompted';
  static const permissionGranted = 'notification_permission_granted';
  static const permissionDenied = 'notification_permission_denied';
}
