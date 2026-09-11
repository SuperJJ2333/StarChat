import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:matrix/matrix.dart';

final class _SnapshotClient extends Client {
  _SnapshotClient() : super('conversation-snapshot-performance');
  final roomsForTest = <Room>[];
  @override
  List<Room> get rooms => roomsForTest;
}

final class _MeasuredRoom extends Room {
  _MeasuredRoom({required super.id, required super.client});
  final users = <User>[];
  int participantReads = 0;

  @override
  String get name => 'Room $id';

  @override
  List<User> getParticipants(
      [List<Membership> membershipFilter = const [
        Membership.join,
        Membership.invite,
        Membership.knock,
      ]]) {
    participantReads++;
    return users
        .where((user) => membershipFilter.contains(user.membership))
        .toList();
  }
}

void main() {
  test('500-room snapshots project members only for dirty group rooms',
      () async {
    final client = _SnapshotClient();
    final groups = <_MeasuredRoom>[];
    for (var roomIndex = 0; roomIndex < 500; roomIndex++) {
      final room = _MeasuredRoom(id: '!room$roomIndex:test', client: client);
      if (roomIndex < 50) {
        groups.add(room);
        room.users.addAll([
          for (var memberIndex = 0; memberIndex < 1000; memberIndex++)
            User('@member$memberIndex:test',
                membership: 'join',
                displayName: 'Member $memberIndex',
                room: room),
        ]);
      }
      client.roomsForTest.add(room);
    }
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));

    final first = await matrix.conversations.snapshot();
    final baselineProjectionReads =
        groups.fold<int>(0, (sum, room) => sum + room.participantReads);
    expect(first.rooms.length, 500);
    expect(baselineProjectionReads, 50,
        reason: 'the baseline projects each populated group once');

    final second = await matrix.conversations.snapshot();
    final noOpProjectionReads =
        groups.fold<int>(0, (sum, room) => sum + room.participantReads);
    expect(noOpProjectionReads, baselineProjectionReads,
        reason:
            'display metadata may be read independently; no member projection re-runs');
    expect(identical(first.rooms.first.members, second.rooms.first.members),
        isTrue);

    final changedRoom = groups[17];
    final changedUser = User('@member0:test',
        membership: 'join', displayName: 'Renamed', room: changedRoom);
    changedRoom.users[0] = changedUser;
    changedRoom.setState(changedUser);
    final third = await matrix.conversations.snapshot();
    expect(changedRoom.participantReads, 2);
    expect(
        groups
            .where((room) => room != changedRoom)
            .every((room) => room.participantReads == 1),
        isTrue);
    expect(third.rooms[17].members.first.displayName, 'Renamed');
    expect(first.rooms[17].members.first.displayName, 'Member 0');
  });
}
