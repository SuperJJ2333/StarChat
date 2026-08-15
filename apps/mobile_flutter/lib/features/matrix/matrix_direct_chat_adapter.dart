import 'package:matrix/matrix.dart';

import 'direct_chat_controller.dart';

final class MatrixDirectChatBackend implements DirectChatBackend {
  const MatrixDirectChatBackend(this.client);
  final Client client;

  @override
  Future<DirectChatRoom?> findJoinedDirectRoom(String matrixUserId) async {
    final roomId = client.getDirectChatFromUserId(matrixUserId);
    if (roomId == null) return null;
    final room = client.getRoomById(roomId);
    if (room == null ||
        room.membership != Membership.join ||
        !room.isDirectChat) {
      return null;
    }
    return _snapshot(room);
  }

  @override
  Future<String> createEncryptedDirectRoom(String matrixUserId) async {
    final roomId = await client.createRoom(
      invite: [matrixUserId],
      isDirect: true,
      preset: CreateRoomPreset.trustedPrivateChat,
      initialState: [
        StateEvent(
          type: EventTypes.Encryption,
          content: {
            'algorithm': Client.supportedGroupEncryptionAlgorithms.first,
          },
        ),
      ],
    );
    await client.waitForRoomInSync(roomId, join: true);
    await Room(id: roomId, client: client).addToDirectChat(matrixUserId);
    return roomId;
  }

  @override
  Future<DirectChatRoom> waitForRoom(String roomId) async {
    var room = client.getRoomById(roomId);
    if (room == null || room.membership != Membership.join) {
      await client.waitForRoomInSync(roomId, join: true);
      room = client.getRoomById(roomId);
    }
    if (room == null) throw StateError('Created Matrix room is unavailable');
    return _snapshot(room);
  }

  Future<DirectChatRoom> _snapshot(Room room) async {
    final members = await room.requestParticipants();
    return DirectChatRoom(
      roomId: room.id,
      encrypted: room.encrypted,
      joinedMemberCount: members.length,
      participantIds: members.map((member) => member.id).toSet(),
    );
  }
}
