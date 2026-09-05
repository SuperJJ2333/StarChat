import '../../core/business_api_client.dart';
import 'group_chat_controller.dart';

/// Creates the encrypted room locally, then asks the business authority to
/// join every opted-in friend using a short-lived server-side Matrix session.
final class ServerAutoJoinGroupGateway implements GroupChatGateway {
  ServerAutoJoinGroupGateway({required this.api, required this.matrix});

  final BusinessApiClient api;
  final GroupChatGateway matrix;

  @override
  Future<String> createEncryptedGroupChat({
    required String name,
    required List<String> matrixUserIds,
  }) async {
    final contacts = await api.listContacts();
    final byMatrixId = {
      for (final contact in contacts) contact.matrixUserId: contact
    };
    final inviteeUserIds = <String>[];
    for (final matrixUserId in matrixUserIds) {
      final contact = byMatrixId[matrixUserId];
      if (contact == null) throw StateError('只能邀请好友加入群聊');
      inviteeUserIds.add(contact.userId);
    }
    final roomId = await matrix.createEncryptedGroupChat(
      name: name,
      matrixUserIds: matrixUserIds,
    );
    await api.requestServerGroupAutoJoin(
      roomId: roomId,
      inviteeUserIds: inviteeUserIds,
    );
    return roomId;
  }
}
