/// 通知事件模型（PRD §49）。
///
/// 事件由 Matrix 同步侧构建，供 [NotificationPolicyEngine] 决策。
/// 通话（P0）不经过该模型：来电 UI 与铃声由通话状态机（CallController /
/// CallAlerts）驱动，避免双重来电界面（PRD §9/§11）。
library;

enum NotificationEventType { chatMessage, businessEvent }

/// 消息内容类型，用于摘要标签与音效映射（PRD §8）。
enum NotificationMessageKind {
  text,
  image,
  video,
  voice,
  file,
  redPacket,
  transfer,
  nudge,
  callSummary,
  other,
}

final class NotificationEvent {
  const NotificationEvent({
    required this.eventId,
    required this.conversationId,
    required this.senderId,
    required this.timestamp,
    this.senderName = '',
    this.conversationName = '',
    this.eventType = NotificationEventType.chatMessage,
    this.messageKind = NotificationMessageKind.text,
    this.messagePreview = '',
    this.isMention = false,
    this.avatarUrl,
    this.unreadCount,
    this.isSystem = false,
  });

  /// 去重主键（PRD §25：Matrix 与 Push 双通道同一事件只提醒一次）。
  final String eventId;

  /// 会话（Matrix 房间）ID，同时是通知聚合键（PRD §16/§42）。
  final String conversationId;

  final String senderId;
  final String senderName;

  /// 会话展示名（私聊为对方昵称/备注，群聊为群名）。
  final String conversationName;

  final NotificationEventType eventType;
  final NotificationMessageKind messageKind;

  /// 消息摘要（已按 PRD §8 规则生成 [图片]/[语音]/[红包] 等标签；
  /// 群聊含"发送者："前缀）。E2EE 解密只发生在设备本地。
  final String messagePreview;

  /// 是否 @我（PRD §28）。
  final bool isMention;

  /// 发送者头像（业务头像 URL；系统通知大图标，缺省占位）。
  final String? avatarUrl;

  /// 该会话当前未读数（含本条；系统通知 number 角标）。
  final int? unreadCount;

  /// 是否系统/业务通知（PRD §3 P3）。
  final bool isSystem;

  final DateTime timestamp;
}
