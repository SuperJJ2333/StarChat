import 'package:matrix/matrix.dart';

import 'direct_chat_controller.dart';

final class MatrixDirectChatBackend implements DirectChatBackend {
  const MatrixDirectChatBackend(this.client);
  final Client client;

  @override
  Future<DirectChatRoom?> findJoinedDirectRoom(String matrixUserId) async {
    final roomId = client.getDirectChatFromUserId(matrixUserId);
    if (roomId != null) {
      final room = client.getRoomById(roomId);
      if (room != null &&
          room.membership == Membership.join &&
          room.isDirectChat) {
        return _snapshot(room);
      }
    }
    // 新好友场景：对方创建 DM 后我方尚处于「受邀未加入」状态。自动接受
    // 邀请并补写 m.direct，否则会重复建第二个房间或直接报错。
    for (final room in client.rooms) {
      if (room.membership != Membership.invite || !room.isDirectChat) continue;
      final participants =
          await room.requestParticipants([Membership.join, Membership.invite]);
      if (!participants.any((member) => member.id == matrixUserId)) continue;
      await room.join();
      await client.waitForRoomInSync(room.id, join: true);
      final joined = client.getRoomById(room.id);
      if (joined != null && joined.membership == Membership.join) {
        await joined.addToDirectChat(matrixUserId);
        return _snapshot(joined);
      }
    }
    return null;
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
    // 成员按 join+invite 口径统计：新好友的 DM 在对方接受邀请前只有
    // 一方 joined，会话必须允许该状态存在（否则必报"无法打开加密会话"）。
    final members =
        await room.requestParticipants([Membership.join, Membership.invite]);
    return DirectChatRoom(
      roomId: room.id,
      encrypted: room.encrypted,
      joinedMemberCount: members.length,
      participantIds: members.map((member) => member.id).toSet(),
    );
  }
}
