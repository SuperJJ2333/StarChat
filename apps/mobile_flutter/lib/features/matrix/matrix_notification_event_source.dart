import 'dart:async';

import 'package:matrix/matrix.dart';

import '../../core/notification/badge_service.dart'
    show ConversationUnreadSnapshot, UnreadSnapshotSource;
import '../../core/notification/notification_coordinator.dart';
import '../../core/notification/notification_diagnostics.dart';
import '../../core/notification/notification_event.dart';
import 'conversation_preferences.dart';
import 'conversation_presentation.dart';
import 'conversation_read_state.dart';
import 'matrix_room_timeline_adapter.dart'
    show
        changliaoCallMessageType,
        changliaoRedPacketMessageType,
        changliaoTransferMessageType;
import 'mute_exception_policy.dart';
import 'nudge_service.dart' show changliaoNudgeEventType;

/// Matrix 同步 → 通知事件源（PRD §22）。
///
/// 订阅 [Client.onSync]（SDK 在发出前已将事件合入房间内存，lastEvent
/// 为本地解密后的版本）。E2EE 明文只在设备本地使用，绝不外发
/// （apps/mobile_flutter/AGENTS.md）。
final class MatrixNotificationEventSource implements NotificationEventSource {
  MatrixNotificationEventSource({
    required this.client,
    ConversationReadState? readState,
    NotificationDiagnostics? diagnostics,
    DateTime Function()? now,
  })  : readState = readState ?? ConversationReadState.shared(),
        diagnostics = diagnostics ?? NotificationDiagnostics.shared,
        now = now ?? DateTime.now;

  final Client client;
  final ConversationReadState readState;
  final NotificationDiagnostics diagnostics;
  final DateTime Function() now;

  final StreamController<IncomingNotification> _controller =
      StreamController<IncomingNotification>.broadcast();
  StreamSubscription<SyncUpdate>? _subscription;

  /// 订阅后的首个 sync 是会话恢复的全量同步，跳过防历史消息轰炸。
  bool _sawFirstSync = false;

  /// 陈旧事件保护：初始增量同步中很久以前的消息不提醒。
  static const _staleWindow = Duration(minutes: 5);

  @override
  Stream<IncomingNotification> get events => _controller.stream;

  Future<void> start() async {
    if (_subscription != null) return;
    _subscription = client.onSync.stream.listen(_handleSync);
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  void _handleSync(SyncUpdate sync) {
    if (!_controller.hasListener) return;
    if (!_sawFirstSync) {
      _sawFirstSync = true;
      return;
    }
    final joins = sync.rooms?.join;
    if (joins == null || joins.isEmpty) return;
    final currentUserId = client.userID;
    if (currentUserId == null) return;
    final cutoff = now().subtract(_staleWindow);
    var notifiableRooms = 0;
    joins.forEach((roomId, update) {
      final events = update.timeline?.events;
      if (events == null || events.isEmpty) return;
      // PRD §15/§42：同一会话一次同步聚合为一个通知，取最后一条
      // 他人消息事件。
      MatrixEvent? lastIncoming;
      for (final event in events) {
        if (event.senderId == currentUserId) continue;
        if (!_isNotifiableMessage(event)) continue;
        if (event.originServerTs.isBefore(cutoff)) continue;
        lastIncoming = event;
      }
      final incoming = lastIncoming;
      if (incoming == null) return;
      final notification = _build(roomId, incoming, currentUserId);
      if (notification != null) {
        notifiableRooms++;
        _controller.add(notification);
      }
    });
    // sync 到达诊断（仅在有可通知事件时记录，避免每次心跳刷屏）。
    if (notifiableRooms > 0) {
      diagnostics.record(
          NotificationDiagStage.syncArrived, 'rooms=$notifiableRooms');
    }
  }

  /// 只通知消息类事件；通话信令（m.call.*）由通话状态机处理，
  /// 避免 P0 双重来电路径（PRD §9/§11）。
  bool _isNotifiableMessage(MatrixEvent event) {
    final type = event.type;
    return type == EventTypes.Message ||
        type == EventTypes.Encrypted ||
        type == changliaoNudgeEventType;
  }

  IncomingNotification? _build(
    String roomId,
    MatrixEvent raw,
    String currentUserId,
  ) {
    final room = client.getRoomById(roomId);
    if (room == null) return null;

    // 预览与提及检测优先使用 SDK 本地解密后的 lastEvent；ids 不一致
    // （其后又跟了自己/其他事件）时退回通用摘要，绝不为通知阻塞解密。
    final lastEvent = room.lastEvent;
    final Event? decrypted =
        lastEvent != null && lastEvent.eventId == raw.eventId
            ? lastEvent
            : null;

    final isMention = _mentionsCurrentUser(decrypted, currentUserId);
    final preference = preferenceForRoom(room);
    final muteDecision = evaluateMuteNotification(
      MuteExceptionSettings(
        muted: preference.muted,
        notifyMentionMe: preference.notifyMentionMe,
        notifyMentionAll: preference.notifyMentionAll,
        notifyAnnouncement: preference.notifyAnnouncement,
        followedMemberIds: preference.followedMemberIds,
      ),
      MuteEventFacts(
        senderId: raw.senderId,
        mentionsMe: isMention,
        mentionsAll: _mentionsAll(decrypted),
        isAnnouncement: false,
      ),
    );

    final senderName =
        room.unsafeGetUserFromMemoryOrFallback(raw.senderId).calcDisplayname();
    final preview = _preview(room, decrypted, raw, senderName);

    return IncomingNotification(
      event: NotificationEvent(
        eventId: raw.eventId,
        conversationId: roomId,
        senderId: raw.senderId,
        senderName: senderName,
        conversationName: room.getLocalizedDisplayname(),
        messageKind: _messageKind(decrypted, raw),
        messagePreview: preview,
        isMention: isMention,
        timestamp: raw.originServerTs,
      ),
      isOwnMessage: false,
      isCurrentConversation: readState.isRoomOpen(roomId),
      muteDecision: muteDecision,
      isAttention: preference.attention && !preference.muted,
    );
  }

  /// MSC3952 m.mentions.user_ids 优先；兼容正文包含用户 ID/@localpart。
  bool _mentionsCurrentUser(Event? decrypted, String currentUserId) {
    if (decrypted == null) return false;
    final mentions = decrypted.content['m.mentions'];
    if (mentions is Map) {
      final userIds = mentions['user_ids'];
      if (userIds is List && userIds.contains(currentUserId)) return true;
    }
    final body = decrypted.text;
    if (body.contains(currentUserId)) return true;
    final localpart = currentUserId.startsWith('@')
        ? currentUserId.substring(1).split(':').first
        : currentUserId;
    return localpart.isNotEmpty && body.contains('@$localpart');
  }

  bool _mentionsAll(Event? decrypted) {
    if (decrypted == null) return false;
    final mentions = decrypted.content['m.mentions'];
    if (mentions is Map && mentions['room'] == true) return true;
    return decrypted.text.contains('@room');
  }

  NotificationMessageKind _messageKind(Event? decrypted, MatrixEvent raw) {
    final type = decrypted?.type ?? raw.type;
    if (type == changliaoNudgeEventType) {
      return NotificationMessageKind.nudge;
    }
    final messageType = decrypted?.messageType ?? '';
    switch (messageType) {
      case MessageTypes.Image:
        return NotificationMessageKind.image;
      case MessageTypes.Video:
        return NotificationMessageKind.video;
      case MessageTypes.Audio:
        return NotificationMessageKind.voice;
      case MessageTypes.File:
        return NotificationMessageKind.file;
      case changliaoRedPacketMessageType:
        return NotificationMessageKind.redPacket;
      case changliaoTransferMessageType:
        return NotificationMessageKind.transfer;
      case changliaoCallMessageType:
        return NotificationMessageKind.callSummary;
      default:
        return NotificationMessageKind.text;
    }
  }

  /// PRD §8：媒体/红包/转账用固定标签；群聊加"发送者："前缀；
  /// 未解密时不显示正文（隐私优先）。
  String _preview(
      Room room, Event? decrypted, MatrixEvent raw, String senderName) {
    String content;
    if (decrypted != null) {
      final mediaSummary = conversationEventSummaryLabel(
        messageType: decrypted.messageType,
        content: decrypted.content,
        eventType: decrypted.type,
      );
      content = (mediaSummary ?? decrypted.text);
      if (content.isEmpty) content = '[新消息]';
    } else {
      final mediaSummary = conversationEventSummaryLabel(
        messageType: raw.type == EventTypes.Encrypted
            ? ''
            : (raw.content['msgtype']?.toString() ?? ''),
        content: const {},
        eventType: raw.type,
      );
      content = mediaSummary ?? '[新消息]';
    }
    if (room.isDirectChat) return content;
    final sender = senderName.isEmpty ? '好友' : senderName;
    return '$sender：$content';
  }
}

/// 桌面角标未读快照源（PRD §36：服务器计数为事实来源）。
final class MatrixUnreadSnapshotSource implements UnreadSnapshotSource {
  MatrixUnreadSnapshotSource({
    required this.client,
    ConversationReadState? readState,
  }) : readState = readState ?? ConversationReadState.shared();

  final Client client;
  final ConversationReadState readState;

  @override
  Future<List<ConversationUnreadSnapshot>> load() async {
    final currentUserId = client.userID;
    if (currentUserId == null) return const [];
    return [
      for (final room in client.rooms)
        ConversationUnreadSnapshot(
          roomId: room.id,
          unread: readState.unreadCount(
            roomId: room.id,
            serverUnreadCount: room.notificationCount,
            lastEventId: room.lastEvent?.eventId,
            lastEventSenderId: room.lastEvent?.senderId,
            currentUserId: currentUserId,
            manualUnread: preferenceForRoom(room).manualUnread,
          ),
          isMuted: preferenceForRoom(room).muted,
          manualUnread: preferenceForRoom(room).manualUnread,
        ),
    ];
  }
}
