import 'matrix_e2ee_client.dart';

/// 会话身份解析（Conversation Identity Layer）：**同一好友在消息列表只允许
/// 出现一行**。
///
/// 背景（重复会话缺陷 0919）：`m.direct` 中同一 peer 可能挂多个已加入房间
/// （历史房间、旧版本建房、`avoidRoomId` 显式新建都会留下旧房间），而消息
/// 列表逐行展示 joined 房间，于是同一好友渲染两条"相同会话"。
///
/// 身份 key：
/// - 私聊 = `sorted([selfUserId, directPeerId])` 拼接——与房间号无关，线路
///   的正反投影得到同一个 key；
/// - 群聊 = roomId（群聊没有"同一身份多个房间"的合法形态）。
///
/// Primary room 选择规则（确定性，依次比较）：
/// 1. **canonical roomId**——服务端已有 canonical 映射（经收敛服务写入
///    [DuplicateRoomRegistry]）且命中候选时优先；
/// 2. **本地消息数量最多**——避免用户进入一个空白的新房间；
/// 3. `lastActivityAt` 最新；
/// 4. roomId 字典序兜底。
///
/// 另有一条高于以上规则的产品安全护栏：可见房间总是优先成为代表——被本机
/// 隐藏（删除该聊天）的房间绝不能压制同一身份下仍可见的房间。
///
/// 落选房间仅从列表隐藏：不 leave、不改成员关系、不动 preference。
/// 纯函数、确定性、可幂等重入：对输出再次解析不产生任何变化。

/// 私聊身份 key：排序后的 userPair（方向无关）。
String directConversationIdentityKey(
    {required String? selfUserId, required String peerId}) {
  final pair = <String>[selfUserId ?? '', peerId]..sort();
  return pair.join('\u0000');
}

/// 房间的身份 key：私聊按排序 userPair，其余按 roomId。
/// `directPeerId` 缺失的房间没有可证明的对端身份，退回 roomId 独立保留，
/// 绝不参与按 peer 的去重（防止误删）。
String conversationIdentityKey(MatrixConversationRoomSnapshot room,
        {required String? selfUserId}) =>
    conversationIdentityKeyOf(
      isDirect: room.isDirect,
      directPeerId: room.directPeerId,
      roomId: room.id,
      selfUserId: selfUserId,
    );

/// 身份 key 的通用形态：供非快照会话条目（转发目标等）复用同一规则。
String conversationIdentityKeyOf({
  required bool isDirect,
  required String? directPeerId,
  required String roomId,
  required String? selfUserId,
}) {
  final peer = directPeerId;
  if (!isDirect || peer == null || peer.isEmpty) return 'room:$roomId';
  return 'direct:${directConversationIdentityKey(selfUserId: selfUserId, peerId: peer)}';
}

/// 对会话快照做身份解析：同一身份只保留一个 primary 代表，输出保持输入
/// 相对顺序。快照契约：被本机隐藏（删除该聊天）的房间**仍出现在快照中**
/// （隐藏过滤由 UI 层的 activeRooms 负责），因此隐藏房间也参与"代表"
/// 选举，但可见房间总是优先。
List<MatrixConversationRoomSnapshot> resolveConversationIdentities(
  List<MatrixConversationRoomSnapshot> rooms, {
  required String? selfUserId,
  String? Function(String peerUserId)? primaryRoomIdOf,
  int Function(MatrixConversationRoomSnapshot room)? localMessageCountOf,
}) =>
    resolveIdentityRepresentatives<MatrixConversationRoomSnapshot>(
      rooms,
      selfUserId: selfUserId,
      isDirectOf: (room) => room.isDirect,
      directPeerIdOf: (room) => room.directPeerId,
      roomIdOf: (room) => room.id,
      isHiddenOf: (room) => room.preference.hidden,
      messageCountOf:
          localMessageCountOf == null ? null : (room) => localMessageCountOf(room),
      lastActivityOf: (room) => room.lastActivityAt,
      primaryRoomIdOf: primaryRoomIdOf,
    );

/// 任意"会话条目"类型的身份代表选举：私聊按排序 userPair 分组，群聊按
/// roomId 分组，每组按 primary 规则选出一个代表。输出保持输入相对顺序。
List<T> resolveIdentityRepresentatives<T>(
  List<T> items, {
  required String? selfUserId,
  required bool Function(T) isDirectOf,
  required String? Function(T) directPeerIdOf,
  required String Function(T) roomIdOf,
  required bool Function(T) isHiddenOf,
  required int Function(T)? messageCountOf,
  required DateTime? Function(T) lastActivityOf,
  String? Function(String peerUserId)? primaryRoomIdOf,
}) {
  final groups = <String, List<T>>{};
  final keys = <T, String>{};
  for (final item in items) {
    final key = conversationIdentityKeyOf(
      isDirect: isDirectOf(item),
      directPeerId: directPeerIdOf(item),
      roomId: roomIdOf(item),
      selfUserId: selfUserId,
    );
    keys[item] = key;
    groups.putIfAbsent(key, () => <T>[]).add(item);
  }
  final winners = <String, T>{};
  for (final entry in groups.entries) {
    final peer = directPeerIdOf(entry.value.first);
    final primary = (peer == null || peer.isEmpty || primaryRoomIdOf == null)
        ? null
        : primaryRoomIdOf(peer);
    winners[entry.key] = entry.value.reduce(
        (incumbent, candidate) => _preferCandidate(
              candidate,
              incumbent,
              primaryRoomId: primary,
              isHiddenOf: isHiddenOf,
              roomIdOf: roomIdOf,
              messageCountOf: messageCountOf,
              lastActivityOf: lastActivityOf,
            )
            ? candidate
            : incumbent);
  }
  return [
    for (final item in items)
      if (identical(winners[keys[item]], item)) item
  ];
}

bool _preferCandidate<T>(
  T candidate,
  T incumbent, {
  required String? primaryRoomId,
  required bool Function(T) isHiddenOf,
  required String Function(T) roomIdOf,
  required int Function(T)? messageCountOf,
  required DateTime? Function(T) lastActivityOf,
}) {
  // 规则零（产品安全护栏）：可见房间优先成为代表。
  if (isHiddenOf(incumbent) != isHiddenOf(candidate)) {
    return !isHiddenOf(candidate);
  }
  // 规则一：canonical / primary roomId（未命中候选时忽略）。
  if (primaryRoomId != null && primaryRoomId.isNotEmpty) {
    final candidateIsPrimary = roomIdOf(candidate) == primaryRoomId;
    final incumbentIsPrimary = roomIdOf(incumbent) == primaryRoomId;
    if (candidateIsPrimary != incumbentIsPrimary) return candidateIsPrimary;
  }
  // 规则二：本地消息数量最多（避免进入空白新房间）。
  if (messageCountOf != null) {
    final candidateMessages = messageCountOf(candidate);
    final incumbentMessages = messageCountOf(incumbent);
    if (candidateMessages != incumbentMessages) {
      return candidateMessages > incumbentMessages;
    }
  }
  // 规则三：lastActivityAt 最新。
  final epoch0 = DateTime.fromMillisecondsSinceEpoch(0);
  final candidateAt = lastActivityOf(candidate) ?? epoch0;
  final incumbentAt = lastActivityOf(incumbent) ?? epoch0;
  if (candidateAt != incumbentAt) return candidateAt.isAfter(incumbentAt);
  // 规则四：roomId 字典序兜底（确定性）。
  return roomIdOf(candidate).compareTo(roomIdOf(incumbent)) < 0;
}
