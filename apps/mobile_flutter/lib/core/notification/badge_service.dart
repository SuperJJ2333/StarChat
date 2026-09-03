import 'package:flutter/services.dart';

import 'notification_preferences.dart';

/// 单个会话的未读快照（聚合桌面角标用）。
final class ConversationUnreadSnapshot {
  const ConversationUnreadSnapshot({
    required this.roomId,
    required this.unread,
    required this.isMuted,
    this.manualUnread = false,
  });

  final String roomId;

  /// 服务器权威未读计数（PRD §36：Server unread 为事实来源）。
  final int unread;
  final bool isMuted;

  /// 手动标记未读不是真实未读，不计入桌面角标。
  final bool manualUnread;
}

/// PRD §35：角标 = 所有未读会话的真实未读总数；静音会话按设置计入；
/// 自己发送、查看中已读、手动标为未读不计入。
int aggregateLauncherBadge({
  required NotificationPreferenceValues prefs,
  required Iterable<ConversationUnreadSnapshot> conversations,
}) {
  var total = 0;
  for (final conversation in conversations) {
    if (conversation.manualUnread) continue;
    if (conversation.unread <= 0) continue;
    if (conversation.isMuted && !prefs.mutedConversationsInBadge) continue;
    total += conversation.unread;
  }
  return total;
}

abstract interface class LauncherBadgeGateway {
  Future<void> updateCount(int count);
}

/// 生产网关：自建 MethodChannel（chatflow/badge）。
/// Android 侧由 MainActivity 经 ShortcutBadger 适配厂商启动器，
/// iOS 侧由 AppDelegate 写 UIApplication 角标；不支持/异常一律静默——
/// 角标是尽力而为的增强反馈，不影响核心通知链路。
final class MethodChannelLauncherBadgeGateway implements LauncherBadgeGateway {
  const MethodChannelLauncherBadgeGateway();

  static const _channel = MethodChannel('chatflow/badge');

  @override
  Future<void> updateCount(int count) async {
    try {
      if (count <= 0) {
        await _channel.invokeMethod<void>('clear');
        return;
      }
      await _channel.invokeMethod<void>('updateCount', {'count': count});
    } catch (_) {
      // 原生侧未注册（测试环境）或启动器不支持：静默。
    }
  }
}

/// 未读快照来源（由 Matrix 侧实现，隔离 SDK 依赖便于测试）。
abstract interface class UnreadSnapshotSource {
  Future<List<ConversationUnreadSnapshot>> load();
}
