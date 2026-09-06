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
          'chatflow_messages_v2',
          '消息通知',
          channelDescription: '收到新的好友申请时提醒',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
        ),
        iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
      ),
      payload: 'friend-requests',
    );
  }
}

/// 周期性巡检好友申请：红点 = 未处理申请数；签名（申请时间+内容）变化
/// 触发系统通知。重复申请更新原记录 → 通知弹窗触发，但红点数字不累计；
/// 已处理后再次申请会产生新记录 → 通知 + 红点一并累计。
final class FriendRequestWatch {
  FriendRequestWatch(this.api, this.prefs,
      {this.notifier,
      this.accountKey = '',
      this.onOutgoingAccepted,
      this.onPendingCount});

  final void Function(int count)? onPendingCount;
  static String pendingKey(String accountKey) =>
      'friend-request-pending-v1:$accountKey';
  final String accountKey;
  final Future<void> Function(Map request)? onOutgoingAccepted;
  Future<int>? _polling;
  String get _seenStorageKey => '$seenKey:$accountKey';
  String get _greetedKey => 'friend-request-greeted-v1:$accountKey';

  static const seenKey = 'friend-request-seen-v1';

  final BusinessApiClient api;
  final SharedPreferences prefs;
  final FriendRequestNotifier? notifier;

  Map<String, String> _seen() {
    final raw = prefs.getString(_seenStorageKey);
    if (raw == null) return {};
    try {
      return (json.decode(raw) as Map).cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveSeen(Map<String, String> seen) async {
    await prefs.setString(_seenStorageKey, json.encode(seen));
  }

  /// 巡检一次，返回当前未处理申请数量（红点数字）。
  Future<int> poll() =>
      _polling ??= _pollOnce().whenComplete(() => _polling = null);

  Future<int> _pollOnce() async {
    final body = await api.friendRequests();
    final allItems =
        ((body['items'] as List?) ?? const []).whereType<Map>().toList();
    final items = allItems
        .whereType<Map>()
        .where((item) =>
            item['direction'] != 'OUTGOING' &&
            item['status']?.toString() == 'PENDING')
        .toList();

    onPendingCount?.call(items.length);
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
    final pending =
        prefs.getStringList(pendingKey(accountKey))?.toSet() ?? <String>{};
    for (final request in allItems) {
      if (request['direction'] == 'OUTGOING' &&
          request['status'] == 'PENDING' &&
          request['id'] != null) {
        pending.add(request['id'].toString());
      }
    }
    await prefs.setStringList(pendingKey(accountKey), pending.toList());
    final greeted = prefs.getStringList(_greetedKey)?.toSet() ?? <String>{};
    final send = onOutgoingAccepted;
    if (send != null) {
      for (final request in allItems) {
        final id = request['id']?.toString();
        if (id == null ||
            greeted.contains(id) ||
            !pending.contains(id) ||
            request['direction'] != 'OUTGOING' ||
            request['status'] != 'ACCEPTED') {
          continue;
        }
        try {
          await send(request);
          greeted.add(id);
          await prefs.setStringList(_greetedKey, greeted.toList());
        } catch (_) {
          // 保留待发状态；重试使用同一 Matrix transaction ID。
        }
      }
    }
    return items.length;
  }
}
