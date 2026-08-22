import 'dart:async';

final class GroupInvitationAutoJoinFailure {
  const GroupInvitationAutoJoinFailure({
    required this.roomId,
    required this.errorType,
  });

  final String roomId;
  final String errorType;
}

final class GroupInvitationAutoJoinResult {
  const GroupInvitationAutoJoinResult({
    required this.joinedRoomIds,
    required this.failures,
  });

  final List<String> joinedRoomIds;
  final List<GroupInvitationAutoJoinFailure> failures;
}

/// Joins Matrix group invitations as part of background synchronisation.
///
/// StarChat presents group membership with WeChat semantics: adding a member
/// joins the selected account without requiring a separate accept action.
Future<GroupInvitationAutoJoinResult> autoJoinInvitedRoomIds({
  required Iterable<String> invitedRoomIds,
  required Future<void> Function(String roomId) joinRoom,
}) async {
  final joinedRoomIds = <String>[];
  final failures = <GroupInvitationAutoJoinFailure>[];
  for (final roomId in invitedRoomIds.toSet()) {
    try {
      await joinRoom(roomId);
      joinedRoomIds.add(roomId);
    } catch (error) {
      failures.add(GroupInvitationAutoJoinFailure(
        roomId: roomId,
        errorType: error.runtimeType.toString(),
      ));
    }
  }
  return GroupInvitationAutoJoinResult(
    joinedRoomIds: joinedRoomIds,
    failures: failures,
  );
}
