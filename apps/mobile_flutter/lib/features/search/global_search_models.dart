import 'package:flutter/foundation.dart';

/// 全局搜索的 typed 结果模型（禁止再用 String 承载 domain 结果，
/// 否则 roomId / eventId / isDirect / senderId / timestamp 全部丢失）。
@immutable
final class GlobalSearchContactResult {
  const GlobalSearchContactResult({
    required this.userId,
    required this.displayName,
    required this.username,
    this.nickname,
    this.avatarUrl,
    this.cacheKey,
    this.matchedText,
  });

  final String userId;
  final String displayName;
  final String username;
  final String? nickname;
  final String? avatarUrl;
  final String? cacheKey;

  /// 辅助匹配说明（例如命中的畅聊号），可选。
  final String? matchedText;
}

@immutable
final class GlobalSearchRoomResult {
  const GlobalSearchRoomResult({
    required this.roomId,
    required this.displayName,
    required this.isDirect,
    this.memberCount,
    this.avatarSeed,
    this.avatarUrl,
    this.matrixAvatarUri,
    this.matchedText,
  });

  final String roomId;
  final String displayName;

  /// 私聊房间不得进入「群聊」分组。
  final bool isDirect;
  final int? memberCount;
  final String? avatarSeed;
  final String? avatarUrl;
  final Uri? matrixAvatarUri;
  final String? matchedText;
}

@immutable
final class GlobalSearchMessageHit {
  const GlobalSearchMessageHit({
    required this.roomId,
    required this.roomName,
    required this.isGroup,
    required this.eventId,
    required this.senderId,
    required this.senderName,
    required this.timestamp,
    required this.body,
    this.roomAvatarSeed,
    this.roomAvatarUrl,
    this.senderIsSelf = false,
  });

  final String roomId;
  final String roomName;
  final bool isGroup;
  final String eventId;
  final String senderId;
  final String senderName;
  final DateTime timestamp;

  /// 已解密正文（仅本机；绝不进入 Business API）。
  final String body;
  final String? roomAvatarSeed;
  final String? roomAvatarUrl;
  final bool senderIsSelf;

  /// 打开该消息所需的最小导航目标。
  GlobalSearchRoomResult get room => GlobalSearchRoomResult(
        roomId: roomId,
        displayName: roomName,
        isDirect: !isGroup,
        avatarSeed: roomAvatarSeed,
        avatarUrl: roomAvatarUrl,
      );
}

/// 同一会话内的命中聚合（聊天记录按 Conversation 分组）。
@immutable
final class GlobalSearchConversationHit {
  const GlobalSearchConversationHit({
    required this.roomId,
    required this.roomName,
    required this.isGroup,
    required this.hits,
    this.roomAvatarSeed,
    this.roomAvatarUrl,
  });

  final String roomId;
  final String roomName;
  final bool isGroup;
  final List<GlobalSearchMessageHit> hits;
  final String? roomAvatarSeed;
  final String? roomAvatarUrl;

  int get total => hits.length;
  GlobalSearchMessageHit get latest => hits.first;

  /// 只有一条命中时可直接跳转并定位。
  bool get isSingleHit => hits.length == 1;
}

@immutable
final class GlobalSearchResults {
  const GlobalSearchResults({
    this.contacts = const [],
    this.rooms = const [],
    this.conversations = const [],
  });

  static const empty = GlobalSearchResults();

  final List<GlobalSearchContactResult> contacts;
  final List<GlobalSearchRoomResult> rooms;
  final List<GlobalSearchConversationHit> conversations;

  bool get isEmpty =>
      contacts.isEmpty && rooms.isEmpty && conversations.isEmpty;
  bool get isNotEmpty => !isEmpty;
}

/// 按逻辑会话聚合命中，保持「最近命中优先」的稳定顺序。
///
/// 分组键 = [primaryRoomIdOf] 把物理 roomId 归并到逻辑会话（同一好友的
/// primary 房间）；无映射时退回物理 roomId。每条命中的 `hit.roomId` 始终
/// 保留其**来源房间**（sourceRoomId）供点击定位；孤儿房间的命中归并到
/// 主会话名下，打开时必须以只读方式定位，不得作为独立可发送的会话打开。
List<GlobalSearchConversationHit> aggregateConversationHits(
  Iterable<GlobalSearchMessageHit> hits, {
  int maxHitsPerConversation = 200,
  String? Function(String roomId)? primaryRoomIdOf,
}) {
  String conversationKeyOf(GlobalSearchMessageHit hit) {
    final primary = primaryRoomIdOf?.call(hit.roomId);
    return (primary == null || primary.isEmpty) ? hit.roomId : primary;
  }

  final order = <String>[];
  final grouped = <String, List<GlobalSearchMessageHit>>{};
  for (final hit in hits) {
    final key = conversationKeyOf(hit);
    final bucket = grouped.putIfAbsent(key, () {
      order.add(key);
      return <GlobalSearchMessageHit>[];
    });
    if (bucket.length < maxHitsPerConversation) bucket.add(hit);
  }
  return [
    for (final key in order)
      GlobalSearchConversationHit(
        roomId: key,
        roomName: grouped[key]!.first.roomName,
        isGroup: grouped[key]!.first.isGroup,
        hits: List.unmodifiable(grouped[key]!
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp))),
        roomAvatarSeed: grouped[key]!.first.roomAvatarSeed,
        roomAvatarUrl: grouped[key]!.first.roomAvatarUrl,
      ),
  ];
}
