import 'package:matrix/matrix.dart';

import 'duplicate_room_registry.dart';
import 'group_room_authority.dart';

const conversationKindStateType = 'com.chatflow.conversation_kind';
const groupConversationIdentity = 'group';

bool isDirectPeerIdentity(String? peer, String self) =>
    peer != null && peer != self && RegExp(r'^@[^\s:]+:[^\s]+$').hasMatch(peer);

/// Local projection evidence only. This never authorizes a send or a join.
/// Null means retain the physical room, but wait before exposing a list row.
String? admitConversationIdentity(
    Room room, String self, DuplicateRoomRegistry registry) {
  final verified = registry.verifiedPeerIdForRoom(self, room.id);
  if (isDirectPeerIdentity(verified, self)) return verified;
  final retained = registry.peerIdForRoom(self, room.id);

  final peers = <String>{};
  for (final entry in room.client.directChats.entries) {
    if (entry.value is List && (entry.value as List).contains(room.id)) {
      if (!isDirectPeerIdentity(entry.key, self)) return null;
      peers.add(entry.key);
    }
  }
  if (peers.length > 1) return null;
  if (peers.length == 1) {
    if (retained != null && retained != peers.single) return null;
    return peers.single;
  }
  if (isDirectPeerIdentity(retained, self)) return retained;
  // Also supports SDK-backed Room implementations; the real SDK validates
  // this getter against current m.direct, not a stale cached display name.
  final sdkPeer = room.directChatMatrixID;
  if (room.isDirectChat && isDirectPeerIdentity(sdkPeer, self)) return sdkPeer;

  final kind = room.getState(conversationKindStateType)?.content;
  final pair = kind?['participants'];
  if (kind?['kind'] == 'direct' && pair is List) {
    final ids = pair.whereType<String>().toSet();
    if (pair.length == 2 && ids.length == 2 && ids.contains(self)) {
      final peer = ids.firstWhere((id) => id != self);
      if (isDirectPeerIdentity(peer, self)) return peer;
    }
    return null;
  }
  final directEvidence = kind?['kind'] == 'direct' ||
      room.getState('com.chatflow.direct_reservation') != null ||
      room.getState(EventTypes.RoomMember, self)?.content['is_direct'] == true;
  if (directEvidence) {
    // Two members alone do NOT prove a DM. Use them only after explicit DM
    // evidence, and only when local state is complete (no /members request).
    if (room.partial || !room.participantListComplete) return null;
    final members = room.getParticipants();
    final ids = members.map((member) => member.id).toSet();
    if (ids.length != 2 || !ids.contains(self)) return null;
    final peer = ids.firstWhere((id) => id != self);
    return isDirectPeerIdentity(peer, self) ? peer : null;
  }
  if (registry.isKnownGroup(self, room.id)) return groupConversationIdentity;
  final events = room.getState(EventTypes.RoomPowerLevels)?.content['events'];
  final legacyGroup = events is Map &&
      events.containsKey(groupSettingsStateType) &&
      events.containsKey(groupAnnouncementStateType);
  if (kind?['kind'] == 'group' ||
      legacyGroup ||
      room.getState(groupSettingsStateType) != null ||
      room.getState(groupAnnouncementStateType) != null ||
      room.isSpace) {
    return groupConversationIdentity;
  }
  // Legacy groups predate the explicit kind/authority keys. Positive complete
  // multiparty membership is incompatible with the app's two-party DM model.
  // All private/conflicting evidence above takes precedence; invites don't count.
  if (!room.partial &&
      (room.summary.mJoinedMemberCount ?? 0) >= 3 &&
      room.participantListComplete) {
    final joined = room.getParticipants([Membership.join]);
    if (joined.length >= 3 && joined.any((member) => member.id == self)) {
      return groupConversationIdentity;
    }
  }
  // In particular, don't guess from a name, encryption or two participants.
  return null;
}
