import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';

void main() {
  MatrixRoomMemberSnapshot member(String id, {bool joined = true}) =>
      MatrixRoomMemberSnapshot(
        id: id,
        displayName: id,
        avatarUri: null,
        isJoined: joined,
      );

  test('joined member count includes the sender once and excludes non-joined',
      () {
    expect(
      redPacketJoinedMemberCount([
        member('self'),
        member('bob'),
        member('bob'),
        member('left', joined: false),
        member('invited', joined: false),
      ], 'self'),
      2,
    );
  });

  test('missing or non-joined sender fails instead of inventing membership',
      () {
    expect(
      () => redPacketJoinedMemberCount([member('bob')], null),
      throwsStateError,
    );
    expect(
      () => redPacketJoinedMemberCount(
          [member('self', joined: false), member('bob')], 'self'),
      throwsStateError,
    );
  });
}
