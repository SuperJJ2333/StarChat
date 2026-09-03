import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/business_api_client.dart';

final class FriendRequestNotifier {
  FriendRequestNotifier({FlutterLocalNotificationsPlugin? plugin})
      : plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin plugin;

  /// 展示好友申请系统通知。
  ///
  /// 不调用 plugin.initialize、不注册点击回调：点击回调只能有一个注册
  /// 者（最后 initialize 者胜出），统一由 FlutterLocalSystemNotification
  /// Presenter 注册并按 payload 集中分发（'friend-requests' → 好友申请页）。
  /// 渠道由通知详情隐式创建；权限由 NotificationCoordinator 上下文式申请
  /// （PRD §33），此处不抢先申请。
  Future<void> show({
    required String nickname,
    required String message,
    required String signature,
  }) async {
    await plugin.show(
      signature.hashCode & 0x7fffffff,
      '新的朋友请求',
      message.isEmpty ? '$nickname 请求添加你为朋友' : '$nickname：$message',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'changliao_friend_requests',
          '好友申请',
          channelDescription: '收到新的好友申请时提醒',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      payload: 'friend-requests',
    );
  }
}

/// 周期性巡检好友申请：红点 = 未处理申请数；签名（申请时间+内容）变化
/// 触发系统通知。重复申请更新原记录 → 通知弹窗触发，但红点数字不累计；
/// 已处理后再次申请会产生新记录 → 通知 + 红点一并累计。
final class FriendRequestWatch {
  FriendRequestWatch(this.api, this.prefs, {this.notifier});

  static const seenKey = 'friend-request-seen-v1';

  final BusinessApiClient api;
  final SharedPreferences prefs;
  final FriendRequestNotifier? notifier;

  Map<String, String> _seen() {
    final raw = prefs.getString(seenKey);
    if (raw == null) return {};
    try {
      return (json.decode(raw) as Map).cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveSeen(Map<String, String> seen) async {
    await prefs.setString(seenKey, json.encode(seen));
  }

  /// 巡检一次，返回当前未处理申请数量（红点数字）。
  Future<int> poll() async {
    final body = await api.friendRequests();
    final items = ((body['items'] as List?) ?? const [])
        .whereType<Map>()
        .where((item) => item['status']?.toString() == 'PENDING')
        .toList();

    final seen = _seen();
    var seenChanged = false;
    for (final item in items) {
      final id = item['id']?.toString();
      if (id == null) continue;
      final signature =
          '${item['requested_at'] ?? ''}|${item['message'] ?? ''}';
      final known = seen[id];
      if (known == signature) continue;
      seen[id] = signature;
      seenChanged = true;
      final nickname = item['nickname']?.toString() ?? '好友';
      await notifier?.show(
        nickname: nickname,
        message: item['message']?.toString() ?? '',
        signature: '$id:$signature',
      );
    }
    // 已处理的申请从签名表中清理，保证"处理后再申请"被视为新记录。
    final liveIds = {for (final item in items) item['id']?.toString() ?? ''};
    if (seen.keys.any((id) => !liveIds.contains(id))) {
      seen.removeWhere((id, _) => !liveIds.contains(id));
      seenChanged = true;
    }
    if (seenChanged) await _saveSeen(seen);
    return items.length;
  }
}
