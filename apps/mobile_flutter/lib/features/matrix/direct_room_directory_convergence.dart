import 'package:matrix/matrix.dart';

import 'duplicate_room_registry.dart';

/// m.direct 目录收敛：**同一好友只保留一个已加入房间条目**（重复会话缺陷
/// 0919 的数据层修复）。
///
/// `m.direct` 中同一 peer 的多 roomId 是历史演化产物（协调机制上线前的旧
/// 房间、旧版本 App 建房、`avoidRoomId` 显式新建残留），SDK 的
/// `addToDirectChat` 只追加不清除。多 joined 房间会让消息列表出现两条
/// "相同会话"，也让 `getDirectChatFromUserId` 的选择不确定。
///
/// 规则：
/// - 只有某 peer 挂**多个本地已加入（join）房间**时才收敛该 peer；
/// - 胜者 = 服务端 canonical 房间（[canonicalRoomIdOf] 可达且本地已加入），
///   否则本地最新活跃（`lastEvent.originServerTs` 最新，roomId 字典序兜底）；
/// - 收敛 = 一次 `setAccountData('m.direct', …)` 把该 peer 重写为
///   `[胜者]`，多 peer 合并为一次写入；
/// - **绝不 leave/forget 任何房间**：落选房间仍 joined、历史完整，只是不再
///   登记为该好友的私聊（列表唯一性由 `ConversationIdentityResolver` 兜底）。

/// 对一个已登录 client 执行目录收敛。零 trust 假设：canonical 查询失败
/// （断网/服务端异常）只降级为本地规则，绝不抛出阻断调用方。
///
/// [registry] 提供时，**仅当服务端 canonical 裁决了胜者**才把落选房间登记
/// 到 [DuplicateRoomRegistry]——本地规则选出的落选者不登记，避免弱证据
/// 覆盖权威映射（解析器的 primary 优先规则只认登记簿里的 canonical）。
Future<void> convergeDirectDirectory(
  Client client, {
  Future<String?> Function(String peerBusinessUserId)? canonicalRoomIdOf,
  String? Function(String matrixPeerUserId)? businessUserIdOf,
  DuplicateRoomRegistry? registry,
}) async {
  final self = client.userID;
  if (self == null || self.isEmpty) return;
  if (registry != null) await registry.ensureLoaded(self);
  final directory = client.directChats;
  final next = Map<String, dynamic>.of(directory);
  var changed = false;
  for (final entry in directory.entries) {
    final roomIds = entry.value;
    if (roomIds is! List) continue;
    final joined = <Room>[];
    for (final id in roomIds) {
      if (id is! String) continue;
      final room = _joinedRoomById(client, id);
      if (room != null) joined.add(room);
    }
    if (joined.length < 2) continue;
    // m.direct 的键是 matrixId；canonical 目录以业务 userId 为键——查询前
    // 必须转换（缺陷 0919 第三轮修正）。转换缺失时跳过查询，绝不误查。
    final matrixPeer = entry.key;
    final businessPeer = businessUserIdOf?.call(matrixPeer);
    final canonical = (businessPeer == null || businessPeer.isEmpty)
        ? null
        : await _canonicalOf(canonicalRoomIdOf, businessPeer);
    final canonicalDecided =
        canonical != null && canonical.isNotEmpty;
    final winner = pickCanonicalDirectRoom(joined, canonicalRoomId: canonical);
    if (canonicalDecided && winner.id == canonical && registry != null) {
      for (final loser in joined) {
        if (loser.id == winner.id) continue;
        await registry.record(
          accountId: self,
          peerId: matrixPeer,
          primaryRoomId: winner.id,
          duplicateRoomId: loser.id,
        );
      }
    }
    final collapsed = <String>[winner.id];
    if (_idsDiffer(roomIds, collapsed)) {
      next[entry.key] = collapsed;
      changed = true;
    }
  }
  if (!changed) return;
  await client.setAccountData(self, 'm.direct', next);
}

Room? _joinedRoomById(Client client, String roomId) {
  final room = client.getRoomById(roomId);
  return room != null && room.membership == Membership.join ? room : null;
}

Future<String?> _canonicalOf(
    Future<String?> Function(String peerUserId)? lookup, String peer) async {
  if (lookup == null) return null;
  try {
    return await lookup(peer);
  } catch (_) {
    // 目录不可达只影响胜者选择精度，不阻断收敛，也不重复抛错。
    return null;
  }
}

/// 胜者规则：canonical（且本地已加入）优先；否则最新活跃，roomId 字典序
/// 兜底（与 `ConversationIdentityResolver` 的确定性口径一致）。
Room pickCanonicalDirectRoom(List<Room> joined, {String? canonicalRoomId}) {
  if (canonicalRoomId != null && canonicalRoomId.isNotEmpty) {
    for (final room in joined) {
      if (room.id == canonicalRoomId) return room;
    }
  }
  final epoch0 = DateTime.fromMillisecondsSinceEpoch(0);
  Room best = joined.first;
  for (final room in joined.skip(1)) {
    final bestAt = best.lastEvent?.originServerTs ?? epoch0;
    final roomAt = room.lastEvent?.originServerTs ?? epoch0;
    if (roomAt.isAfter(bestAt) ||
        (roomAt == bestAt && room.id.compareTo(best.id) < 0)) {
      best = room;
    }
  }
  return best;
}

bool _idsDiffer(List<dynamic> current, List<String> collapsed) {
  if (current.length != collapsed.length) return true;
  for (var i = 0; i < current.length; i++) {
    if (current[i] != collapsed[i]) return true;
  }
  return false;
}
