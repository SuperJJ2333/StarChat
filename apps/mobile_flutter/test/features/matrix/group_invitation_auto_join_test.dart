import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/group_invitation_auto_join.dart';

void main() {
  test('joins every invited group during sync without user confirmation',
      () async {
    final joined = <String>[];

    final result = await autoJoinInvitedRoomIds(
      invitedRoomIds: const [
        '!group-a:example.test',
        '!group-b:example.test',
      ],
      joinRoom: (roomId) async => joined.add(roomId),
    );

    expect(joined, ['!group-a:example.test', '!group-b:example.test']);
    expect(result.joinedRoomIds, joined);
    expect(result.failures, isEmpty);
  });

  test('keeps joining later invitations when one invitation fails', () async {
    final joined = <String>[];

    final result = await autoJoinInvitedRoomIds(
      invitedRoomIds: const [
        '!broken:example.test',
        '!group-b:example.test',
      ],
      joinRoom: (roomId) async {
        if (roomId == '!broken:example.test') throw StateError('denied');
        joined.add(roomId);
      },
    );

    expect(joined, ['!group-b:example.test']);
    expect(result.joinedRoomIds, ['!group-b:example.test']);
    expect(result.failures.single.roomId, '!broken:example.test');
    expect(result.failures.single.errorType, 'StateError');
  });
}
