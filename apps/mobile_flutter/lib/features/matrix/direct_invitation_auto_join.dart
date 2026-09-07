import 'package:matrix/matrix.dart';

/// Accept only encrypted direct invitations from current business contacts.
/// Invite-state members come from stripped sync state: /members is forbidden
/// until join. Full member verification follows join before marking the DM.
Future<Set<String>> autoJoinFriendDirectInvites({
  required Client client,
  required Set<String> friendMatrixIds,
  required Set<String> inFlight,
  Duration operationTimeout = const Duration(seconds: 15),
}) async {
  final self = client.userID;
  if (self == null) return {};
  final joined = <String>{};
  final operations = <Future<void>>[];
  for (final room in List<Room>.of(client.rooms)) {
    if (room.membership != Membership.invite ||
        !room.isDirectChat ||
        !room.encrypted ||
        inFlight.contains(room.id)) {
      continue;
    }
    final invite = room.getState(EventTypes.RoomMember, self);
    final inviter = invite?.senderId;
    if (inviter == null ||
        inviter == self ||
        invite?.content['is_direct'] != true ||
        room.directChatMatrixID != inviter ||
        !friendMatrixIds.contains(inviter)) {
      continue;
    }
    final members = room
        .getParticipants([Membership.join, Membership.invite])
        .map((member) => member.id)
        .toSet();
    if (members.length != 2 ||
        !members.contains(self) ||
        !members.contains(inviter)) {
      continue;
    }
    inFlight.add(room.id);
    operations.add(() async {
      try {
        await room.join().timeout(operationTimeout);
        if (room.membership != Membership.join) {
          await client
              .waitForRoomInSync(room.id, join: true)
              .timeout(operationTimeout);
        }
        final current = client.getRoomById(room.id);
        if (current == null ||
            !current.encrypted ||
            current.membership != Membership.join) {
          return;
        }
        final verified = await current.requestParticipants(
            [Membership.join, Membership.invite]).timeout(operationTimeout);
        final ids = verified.map((member) => member.id).toSet();
        if (ids.length != 2 || !ids.contains(self) || !ids.contains(inviter)) {
          return;
        }
        await current.addToDirectChat(inviter).timeout(operationTimeout);
        joined.add(room.id);
      } catch (_) {
        // A later sync retries pending invites; one failure cannot block others.
      } finally {
        inFlight.remove(room.id);
      }
    }());
  }
  await Future.wait(operations);
  return joined;
}
