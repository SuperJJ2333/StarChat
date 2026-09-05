import 'package:matrix/matrix.dart';

import 'group_chat_controller.dart';

final class MatrixGroupChatBackend implements GroupChatBackend {
  const MatrixGroupChatBackend(this.client);

  final Client client;

  @override
  Future<String> createPrivateEncryptedRoom({
    required String name,
    required List<String> matrixUserIds,
  }) =>
      client.createRoom(
        name: name,
        invite: matrixUserIds,
        isDirect: false,
        preset: CreateRoomPreset.privateChat,
        initialState: [
          StateEvent(
            type: EventTypes.Encryption,
            content: {
              'algorithm': Client.supportedGroupEncryptionAlgorithms.first,
            },
          ),
        ],
      );

  @override
  Future<void> waitUntilJoined(String roomId) =>
      client.waitForRoomInSync(roomId, join: true);
}
