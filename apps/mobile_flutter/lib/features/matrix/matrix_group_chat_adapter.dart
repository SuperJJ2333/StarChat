import 'package:matrix/matrix.dart';

import 'group_chat_controller.dart';
import 'group_room_authority.dart';

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
        powerLevelContentOverride: {
          'users': {client.userID!: 100},
          'users_default': 0,
          'state_default': 50,
          'events': {
            EventTypes.RoomPowerLevels: 100,
            EventTypes.RoomName: 0,
            groupSettingsStateType: 50,
            groupAnnouncementStateType: 50,
          },
        },
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
