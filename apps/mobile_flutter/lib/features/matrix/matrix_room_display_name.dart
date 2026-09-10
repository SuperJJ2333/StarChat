import 'package:matrix/matrix.dart';

/// 问题五：私聊房间的用户可见名称。
///
/// 根因：对方删除会话/退出后，服务端 room summary 的 m.heroes 变为
/// 空列表，私聊房间又没有 m.room.name 和 canonical alias，SDK 的
/// `getLocalizedDisplayname()` 在 heroes 为空时直接兜底返回英文
/// "Empty chat"（空列表不会回退到 m.direct 映射），并通过聊天页标题、
/// 头像回退、全局搜索等界面暴露给用户。
///
/// 规则：房名 → 对方成员 displayname → m.direct 对方 ID localpart；
/// 群聊不做特殊处理，沿用 SDK 行为。只影响显示，不改变可见性规则，
/// 也不删除/隐藏任何历史房间。
String roomDisplayName(Room room) {
  if (room.name.isNotEmpty) return room.name;
  final peerId = room.directChatMatrixID;
  if (peerId != null && peerId.isNotEmpty) {
    final displayName =
        room.unsafeGetUserFromMemoryOrFallback(peerId).calcDisplayname();
    if (displayName.isNotEmpty) return displayName;
    final localpart = peerId.split(':').first.replaceFirst('@', '');
    if (localpart.isNotEmpty) return localpart;
  }
  return room.getLocalizedDisplayname();
}
