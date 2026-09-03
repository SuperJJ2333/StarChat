import 'dart:async';

import '../../core/notification/notification_deduplicator.dart';
import '../../core/notification/notification_diagnostics.dart';

/// 推送载荷（仅不透明标识 + 类型 + 未读数）。
///
/// E2EE 边界：解析白名单只有 event_id/room_id/type/unread 四个键；
/// 任何 content/body/filename/密钥类字段即使出现在 data 中也不会被
/// 读取或转发（有专门测试断言）。
final class PushNotificationPayload {
  const PushNotificationPayload({
    this.eventId,
    this.roomId,
    this.type,
    this.unreadCount,
  });

  final String? eventId;
  final String? roomId;
  final String? type;
  final int? unreadCount;

  /// 是否为来电信令（m.call.*）触发的推送。
  bool get isCall => type != null && type!.startsWith('m.call');

  /// 白名单解析：只提取四个不透明字段。
  static PushNotificationPayload parse(Map<Object?, Object?>? data) {
    if (data == null) return const PushNotificationPayload();
    String? read(String key) {
      final value = data[key];
      if (value is String && value.isNotEmpty) return value;
      return null;
    }

    final unread = data['unread'];
    return PushNotificationPayload(
      eventId: read('event_id'),
      roomId: read('room_id'),
      type: read('type'),
      unreadCount: unread is int
          ? unread
          : unread is num
              ? unread.toInt()
              : null,
    );
  }
}

/// 推送点击路由：
/// 1. 点击时先把 eventId 写入持久去重——系统推送已展示过的事件，
///    App 启动后 Matrix 同步到达时不得再提醒一次；
/// 2. 通知系统/主页面未就绪（冷启动）时挂起，就绪后进入对应会话
///    （与本地通知点击复用同一入口，进会话后本地解密渲染）。
final class PushTapRouter {
  PushTapRouter({
    required Future<void> Function(String roomId) openConversation,
    required this.deduplicator,
    NotificationDiagnostics? diagnostics,
  })  : _openConversation = openConversation,
        diagnostics = diagnostics ?? NotificationDiagnostics.shared;

  final Future<void> Function(String roomId) _openConversation;
  final NotificationDeduplicator deduplicator;
  final NotificationDiagnostics diagnostics;

  bool _ready = false;
  bool _opening = false;
  String? _pendingRoomId;

  bool get hasPending => _pendingRoomId != null;

  void handleTap(PushNotificationPayload payload) {
    final eventId = payload.eventId;
    if (eventId != null) {
      // 系统推送已展示：标记已处理，冷启动同步的同一事件被去重抑制。
      deduplicator.tryProcess(eventId);
    }
    final roomId = payload.roomId;
    if (roomId == null || roomId.isEmpty) {
      diagnostics.record(
          NotificationDiagStage.push, 'tap without room; dropped');
      return;
    }
    if (!_ready) {
      _pendingRoomId = roomId;
      diagnostics.record(
          NotificationDiagStage.push, 'tap queued until session ready',
          eventId: eventId, roomId: roomId);
      return;
    }
    unawaited(_open(roomId, eventId: eventId));
  }

  /// 通知系统就绪（首次同步/主页面挂载完成）后调用：消费挂起的点击。
  void markReady() {
    if (_ready) return;
    _ready = true;
    final pending = _pendingRoomId;
    _pendingRoomId = null;
    if (pending != null) {
      unawaited(_open(pending));
    }
  }

  /// 登出/账号切换：丢弃挂起的路由（不允许跨账号串会话）。
  void reset() {
    _ready = false;
    _pendingRoomId = null;
  }

  Future<void> _open(String roomId, {String? eventId}) async {
    if (_opening) return;
    _opening = true;
    try {
      diagnostics.record(NotificationDiagStage.push, 'tap → open conversation',
          eventId: eventId, roomId: roomId);
      await _openConversation(roomId);
    } finally {
      _opening = false;
    }
  }
}
