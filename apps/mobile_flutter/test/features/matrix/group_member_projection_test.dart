import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/chat_red_packet_sheet.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';

MatrixRoomMemberSnapshot _member(String id, String name, {Uri? avatar}) =>
    MatrixRoomMemberSnapshot(
      id: id,
      displayName: name,
      avatarUri: avatar,
      isJoined: true,
    );

void main() {
  test('群成员投影保留 Matrix 头像与业务身份，并使用好友备注作为显示名', () {
    const me = '@me:test';
    final friend = ContactDetails(
      userId: 'user-alice',
      matrixUserId: '@alice:test',
      username: 'alice',
      nickname: '爱丽丝',
      remark: '项目-爱丽丝',
      avatarUrl: 'https://cdn.test/alice.png',
    );
    final projection = chatRoomMembersFor(
      members: [
        _member(me, '我'),
        _member('@alice:test', 'Alice',
            avatar: Uri.parse('mxc://test/alice')),
        _member('@stranger:test', '路人'),
      ],
      currentUserId: me,
      contactsByMatrixId: {'@alice:test': friend},
    );

    expect(projection.map((member) => member.id),
        ['@alice:test', '@stranger:test'],
        reason: '必须排除自己，且只包含当前房间成员');

    final alice = projection.first;
    expect(alice.name, '项目-爱丽丝', reason: '显示名必须使用好友备注');
    expect(alice.avatarUrl, 'mxc://test/alice',
        reason: 'Matrix 头像必须原样保留给 mxc 解析');
    expect(alice.businessUserId, 'user-alice',
        reason: '好友的业务账号必须直接带入，避免再查询失败');
    expect(alice.businessAvatarUrl, 'https://cdn.test/alice.png');

    final stranger = projection.last;
    expect(stranger.name, '路人');
    expect(stranger.businessUserId, isNull,
        reason: '非好友没有业务身份，留空由选择器按需查询');
  });
}
