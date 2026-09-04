import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'conversation_preferences.dart';
import 'room_timeline_controller.dart';
import 'matrix_room_timeline_adapter.dart' show changliaoCallMessageType;

final class ConversationIdentity {
  const ConversationIdentity({
    required this.matrixUserId,
    this.remark,
    this.nickname,
    this.username,
    this.matrixDisplayName,
  });

  final String matrixUserId;
  final String? remark;
  final String? nickname;
  final String? username;
  final String? matrixDisplayName;
}

String? _normalized(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String _matrixLocalpart(String matrixUserId) {
  final withoutSigil =
      matrixUserId.startsWith('@') ? matrixUserId.substring(1) : matrixUserId;
  return withoutSigil.split(':').first;
}

String directConversationTitle(ConversationIdentity identity) =>
    _normalized(identity.remark) ??
    _normalized(identity.nickname) ??
    _normalized(identity.username) ??
    _normalized(identity.matrixDisplayName) ??
    _matrixLocalpart(identity.matrixUserId);

String conversationSenderName(ConversationIdentity identity) =>
    _normalized(identity.remark) ??
    _normalized(identity.nickname) ??
    _normalized(identity.username) ??
    _normalized(identity.matrixDisplayName) ??
    _matrixLocalpart(identity.matrixUserId);

/// 会话列表摘要：媒体类消息显示固定方括号标签而非文件名/占位文本。
/// 语音/视频通话摘要来自通话结束消息（com.changliao.call）。
String? conversationEventSummaryLabel({
  required String messageType,
  Map<String, dynamic>? content,
  String? eventType,
}) {
  // 通话信令事件（invite/answer/hangup 等）作为最后事件时，
  // 摘要显示通话标签而不是空白。invite 可从 SDP 区分音/视频。
  if (eventType != null && eventType.startsWith('m.call.')) {
    if (eventType == 'm.call.invite') {
      final offer = content?['offer'];
      final sdp = offer is Map ? offer['sdp']?.toString() ?? '' : '';
      return sdp.contains('m=video') ? '[视频通话]' : '[语音通话]';
    }
    return '[语音通话]';
  }
  switch (messageType) {
    case 'm.image':
      return '[图片]';
    case 'm.video':
      return '[视频]';
    case 'm.audio':
      return '[语音]';
    case 'm.file':
      return '[文件]';
    case changliaoCallMessageType:
      return content?['call_type']?.toString() == 'video' ? '[视频通话]' : '[语音通话]';
    default:
      return null;
  }
}

/// 群聊标题：服务端群名（m.room.name）优先；未设置时回退成员清单
/// （调用方须按加入顺序传入）。
String groupConversationTitle(
  List<ConversationIdentity> members, {
  String? groupName,
}) {
  final name = groupName?.trim();
  if (name != null && name.isNotEmpty) return name;
  return members
      .map(conversationSenderName)
      .where((name) => name.isNotEmpty)
      .join('、');
}

String safeConversationMessageContent({
  required bool undecrypted,
  required String messageContent,
}) =>
    undecrypted ? '消息尚未解密' : messageContent;

String groupConversationSubtitle({
  required int unreadCount,
  required String senderName,
  required String messageContent,
  bool redacted = false,
  String? systemSummary,
}) {
  final prefix = unreadCount > 0 ? '[$unreadCount条]' : '';
  final system = _normalized(systemSummary);
  if (system != null) return '$prefix$system';
  final sender = _normalized(senderName) ?? '好友';
  if (redacted) return '$prefix$sender撤回了一条消息';
  return '$prefix$sender：$messageContent';
}

/// 消息是否渲染外层气泡底衬。红包/转账/语音是"自带完整视觉"的卡片，
/// 叠加气泡底衬会出现白底垫彩底的错误观感（如语音绿气泡垫白气泡）。
bool messageBubbleIsDecorated(RoomMessageKind kind) =>
    kind != RoomMessageKind.redPacket &&
    kind != RoomMessageKind.transfer &&
    kind != RoomMessageKind.voice &&
    kind != RoomMessageKind.video &&
    kind != RoomMessageKind.image;

List<User> orderedJoinedMembers(Room room) {
  final joined = room.getParticipants([Membership.join]);
  final byId = {for (final member in joined) member.id: member};
  final order = reconcileMemberOrder(
    preferenceForRoom(room).memberOrderIds,
    joined.map((member) => member.id),
  );
  return [
    for (final id in order)
      if (byId[id] != null) byId[id]!
  ];
}

/// 规格#3：会话类型判定（两个人聊天 ≠ 群聊）。
///
/// DIRECT 必须 isDirectChat（m.direct）且成员恰为 2；**成员==2 但未写
/// m.direct 的房间是 GROUP**（不能当私聊用——避免把历史群误判为单聊）。
enum ConversationRoomType { direct, group }

ConversationRoomType conversationRoomType({
  required bool isDirectChat,
  required int memberCount,
}) =>
    isDirectChat && memberCount == 2
        ? ConversationRoomType.direct
        : ConversationRoomType.group;

/// 群聊导航标题：群主/管理员改过群名时显示“群名（N）”，
/// 默认“群聊（N）”；长名称由调用方以省略号截断。
String groupRoomNavigationTitle(String? groupName, int memberCount) {
  final name = groupName?.trim();
  final label = name == null || name.isEmpty ? '群聊' : name;
  return '$label（$memberCount）';
}

String directRoomNavigationTitle({
  required String? peerMatrixUserId,
  required Map<String, ContactDetails> contactsByMatrixId,
  required String fallbackRoomName,
}) {
  final contact = contactsByMatrixId[peerMatrixUserId];
  if (contact == null) return fallbackRoomName;
  return directConversationTitle(ConversationIdentity(
    matrixUserId: contact.matrixUserId,
    remark: contact.remark,
    nickname: contact.nickname,
    username: contact.username,
  ));
}

Future<List<User>> loadOrderedJoinedMembers(Room room) async {
  await room.requestParticipants([Membership.join]);
  return orderedJoinedMembers(room);
}

/// 聊天内发送者展示名（需求 3 的优先级，纯逻辑可测）：
/// - 私聊：备注名 > 原始昵称（Matrix 成员名）；
/// - 群聊：群昵称 > 备注名 > 原始昵称。Matrix 成员 displayname 未单独
///   设置时等于其全局昵称，故与 [contactNickname] 不同（或非好友无对照）
///   才视为显式设置过群昵称。
/// 示例：好友昵称"一马当先"、备注"兄弟" → 私聊显示"兄弟"；未设群昵称的
/// 群聊也显示"兄弟"；群昵称"二马"的群里显示"二马"。
String resolveChatSenderDisplayName({
  required bool isDirectChat,
  required String memberName,
  String? contactNickname,
  String? remark,
}) {
  final cleanRemark = (remark ?? '').trim();
  final cleanNickname = (contactNickname ?? '').trim();
  if (!isDirectChat) {
    final hasGroupNick = cleanNickname.isEmpty || memberName != cleanNickname;
    if (hasGroupNick) return memberName;
  }
  return cleanRemark.isNotEmpty ? cleanRemark : memberName;
}
