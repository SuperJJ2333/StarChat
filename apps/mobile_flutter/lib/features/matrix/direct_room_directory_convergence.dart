import 'package:matrix/matrix.dart';

import 'duplicate_room_registry.dart';

/// Account-synced associations preserve every source room. m.direct is never
/// destructively collapsed: the app projection selects one representative.
const directConversationAssociationPrefix =
    'com.changliao.direct_conversation.';

/// The business endpoint has verified these room associations for this peer.
/// The client retains identity even before a room arrives in local Matrix sync.
final class DirectRoomAssociations {
  const DirectRoomAssociations(
      {required this.primaryRoomId, required this.roomIds});
  final String primaryRoomId;
  final List<String> roomIds;
}

/// Restore account metadata before projecting or navigating. No join is issued.
Future<void> loadDirectRoomAssociations(
    Client client, DuplicateRoomRegistry registry) async {
  final self = client.userID;
  if (self == null || self.isEmpty) return;
  await registry.ensureLoaded(self);
  for (final event in client.accountData.entries.toList()) {
    if (client.userID != self) return;
    if (!event.key.startsWith(directConversationAssociationPrefix)) continue;
    final data = event.value.content;
    final room = data['room_id'];
    final peer = data['peer_id'];
    final primary = data['primary_room_id'];
    if (room is! String ||
        peer is! String ||
        primary is! String ||
        !room.startsWith('!') ||
        !primary.startsWith('!') ||
        !peer.startsWith('@') ||
        peer == self ||
        event.key !=
            '$directConversationAssociationPrefix${Uri.encodeComponent(room)}') {
      continue;
    }
    await registry.rememberPrimary(self, peer, primary);
    if (room != primary) {
      await registry.record(
          accountId: self,
          peerId: peer,
          primaryRoomId: primary,
          duplicateRoomId: room);
    }
  }
}

/// Recover server-verified historical identity and publish locally known rooms.
/// Network failure preserves existing mappings; it never elects a new authority
/// by local activity. Publishing is metadata-only, with server-side membership
/// verification. No room creation, join, leave, deletion or plaintext is involved.
Future<void> convergeDirectDirectory(
  Client client, {
  Future<String?> Function(String peerBusinessUserId)? canonicalRoomIdOf,
  String? Function(String matrixPeerUserId)? businessUserIdOf,
  Future<DirectRoomAssociations?> Function(String peerBusinessUserId)?
      associationsOf,
  Future<void> Function(String peerBusinessUserId, List<String> roomIds)?
      publishAssociations,
  DuplicateRoomRegistry? registry,
  Iterable<String> knownMatrixPeers = const [],
}) async {
  final self = client.userID;
  if (self == null || self.isEmpty) return;
  final identities = registry ?? DuplicateRoomRegistry();
  await loadDirectRoomAssociations(client, identities);
  if (client.userID != self) return;
  final directory = <String, Set<String>>{
    for (final peer in knownMatrixPeers)
      if (peer.startsWith('@') && peer != self) peer: <String>{}
  };
  for (final entry in client.directChats.entries) {
    if (entry.value is List) {
      directory[entry.key] = (entry.value as List).whereType<String>().toSet();
    }
  }
  for (final entry in identities.entries(self)) {
    directory.putIfAbsent(entry.peerId, () => <String>{})
      ..add(entry.duplicateRoomId)
      ..add(entry.primaryRoomId);
  }
  // Primary-only metadata also identifies a peer when legacy m.direct is empty.
  for (final event in client.accountData.entries) {
    if (!event.key.startsWith(directConversationAssociationPrefix)) continue;
    final peer = event.value.content['peer_id'];
    final room = event.value.content['room_id'];
    if (peer is String &&
        room is String &&
        peer != self &&
        peer.startsWith('@') &&
        room.startsWith('!') &&
        event.key ==
            '$directConversationAssociationPrefix${Uri.encodeComponent(room)}') {
      directory.putIfAbsent(peer, () => <String>{}).add(room);
    }
  }
  for (final entry in directory.entries) {
    if (client.userID != self) return;
    final peer = businessUserIdOf?.call(entry.key);
    if (peer == null || peer.isEmpty) continue;
    DirectRoomAssociations? remote;
    try {
      remote = await associationsOf?.call(peer);
    } catch (_) {/* Retry next sync. */}
    if (client.userID != self) return;
    final remotePrimary = remote?.primaryRoomId;
    final canonical = remotePrimary != null && remotePrimary.startsWith('!')
        ? remotePrimary
        : await _canonicalOf(canonicalRoomIdOf, peer);
    if (client.userID != self) return;
    if (canonical == null || !canonical.startsWith('!')) continue;
    final verifiedRemote = remotePrimary == canonical
        ? remote!.roomIds.where((id) => id.startsWith('!')).toSet()
        : <String>{};
    final localVerified = entry.value.where((id) {
      final room = _joinedRoomById(client, id);
      return room != null && room.encrypted;
    }).toSet();
    final retained = identities
        .entries(self)
        .where((known) => known.peerId == entry.key)
        .map((known) => known.duplicateRoomId);
    final sources = {
      canonical,
      ...localVerified,
      ...verifiedRemote,
      ...retained
    };
    await identities.rememberPrimary(self, entry.key, canonical);
    for (final id in sources) {
      if (client.userID != self) return;
      if (id != canonical) {
        await identities.record(
            accountId: self,
            peerId: entry.key,
            primaryRoomId: canonical,
            duplicateRoomId: id);
      }
      final type =
          '$directConversationAssociationPrefix${Uri.encodeComponent(id)}';
      final body = <String, Object?>{
        'room_id': id,
        'peer_id': entry.key,
        'primary_room_id': canonical
      };
      final previous = client.accountData[type]?.content;
      if (previous?['primary_room_id'] == canonical &&
          previous?['peer_id'] == entry.key &&
          previous?['room_id'] == id) {
        continue;
      }
      try {
        await client.setAccountData(self, type, body);
        if (client.userID != self) return;
        client.accountData[type] = BasicEvent(type: type, content: body);
      } catch (_) {
        /* Keep local identity and retry account metadata next sync. */
      }
    }
    if (publishAssociations != null && localVerified.isNotEmpty) {
      if (client.userID != self) return;
      try {
        await publishAssociations(peer, localVerified.toList()..sort());
      } catch (_) {
        /* Server revalidates rooms; failure never removes local history. */
      }
    }
  }
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
