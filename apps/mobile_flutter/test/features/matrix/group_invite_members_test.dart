import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_info_controller.dart';

/// BUG1 修复断言：
/// 1) 群人数只数真正 join 的成员（invite 不计入 members/标题）；
/// 2) invite 先 Matrix invite、再服务端自动入群（两步顺序与失败降级）；
/// 3) 服务端分桶如实呈现（对方已加入/等待确认/部分失败）。
void main() {
  test('快照：members 只含 join，invitedMembers 单列且不计入标题人数', () {
    const snapshot = GroupChatInfoSnapshot(
      name: '群',
      members: [
        GroupChatMember(matrixUserId: '@a:x', displayName: 'A'),
        GroupChatMember(matrixUserId: '@b:x', displayName: 'B'),
      ],
      invitedMembers: [
        GroupChatMember(
          matrixUserId: '@c:x',
          displayName: 'C',
          membership: Membership.invite,
        ),
      ],
    );
    expect(snapshot.joinedCount, 2, reason: '群人数只数 join');
    expect(snapshot.members.length, 2);
    expect(snapshot.invitedMembers.length, 1);
    expect(snapshot.invitedMembers.single.isJoined, isFalse);
  });

  test('标题人数 = joinedCount（不含待确认邀请）', () {
    final state = GroupChatInfoState(
      status: GroupChatInfoStatus.ready,
      snapshot: GroupChatInfoSnapshot(
        name: '群',
        members: List.generate(
          3,
          (i) => GroupChatMember(matrixUserId: '@m$i:x', displayName: 'M$i'),
        ),
        invitedMembers: const [
          GroupChatMember(
            matrixUserId: '@pending:x',
            displayName: '待确认',
            membership: Membership.invite,
          ),
        ],
      ),
    );
    expect(state.title, '聊天信息(3)');
  });

  test('invite：先 Matrix invite 再服务端自动入群（携带业务 id）', () async {
    final gateway = _RecordingGateway();
    final autoJoinCalls = <(String, List<String>)>[];
    final controller = GroupChatInfoController(
      gateway,
      serverAutoJoin: (roomId, ids) async {
        autoJoinCalls.add((roomId, ids));
        return const GroupAutoJoinOutcome(joinedUserIds: ['u9']);
      },
    );
    await controller.invite('@new:x', businessUserId: 'u9');
    expect(gateway.invited, ['@new:x'], reason: 'Matrix invite 第一步');
    expect(autoJoinCalls.length, 1, reason: '服务端自动入群第二步（恰好一次）');
    expect(autoJoinCalls.single.$1, '!g:x');
    expect(autoJoinCalls.single.$2, ['u9']);
    expect(controller.state.message, '对方已加入群聊');
  });

  test('invite：服务端失败不回滚邀请（等待对方确认）', () async {
    final gateway = _RecordingGateway();
    final controller = GroupChatInfoController(
      gateway,
      serverAutoJoin: (roomId, ids) async => throw StateError('offline'),
    );
    await controller.invite('@new:x', businessUserId: 'u9');
    expect(gateway.invited, ['@new:x'], reason: '邀请仍然成立');
    expect(controller.state.message, '邀请已发送；自动加入暂不可用，等待对方确认');
  });

  test('invite：Matrix invite 失败 → 报错且不触服务端', () async {
    final gateway = _RecordingGateway()..failInvite = true;
    var autoJoinCalled = false;
    final controller = GroupChatInfoController(
      gateway,
      serverAutoJoin: (roomId, ids) async {
        autoJoinCalled = true;
        return null;
      },
    );
    await controller.invite('@new:x', businessUserId: 'u9');
    expect(controller.state.message, contains('添加群成员失败'));
    expect(autoJoinCalled, isFalse);
  });

  test('invite：pending 分桶呈现等待确认文案', () async {
    final controller = GroupChatInfoController(
      _RecordingGateway(),
      serverAutoJoin: (roomId, ids) async =>
          const GroupAutoJoinOutcome(pendingUserIds: ['u9']),
    );
    await controller.invite('@new:x', businessUserId: 'u9');
    expect(controller.state.message, contains('等待对方确认'));
  });

  test('GroupAutoJoinOutcome.fromJson 解析三桶', () {
    final outcome = GroupAutoJoinOutcome.fromJson({
      'room_id': '!g:x',
      'joined_user_ids': ['u1'],
      'pending_user_ids': ['u2'],
      'failed': [
        {'user_id': 'u3', 'code': 'MATRIX_GROUP_JOIN_FAILED'},
      ],
    });
    expect(outcome.joinedUserIds, ['u1']);
    expect(outcome.pendingUserIds, ['u2']);
    expect(outcome.failed, ['u3']);
    expect(outcome.hasFailures, isTrue);
  });
}

final class _RecordingGateway implements GroupChatInfoGateway {
  final invited = <String>[];
  var failInvite = false;

  @override
  String? get roomId => '!g:x';

  @override
  Future<GroupChatInfoSnapshot> load() async => const GroupChatInfoSnapshot(
        name: '群',
        members: [
          GroupChatMember(matrixUserId: '@a:x', displayName: 'A'),
        ],
      );

  @override
  Future<void> invite(String matrixUserId) async {
    if (failInvite) throw StateError('no power');
    invited.add(matrixUserId);
  }

  @override
  Future<void> leave() async {}

  @override
  Future<void> rename(String name) async {}

  @override
  Future<void> setAnnouncement(String announcement) async {}

  @override
  Future<void> setRemark(String remark) async {}

  @override
  Future<void> setPreference(
      GroupChatPreference preference, bool value) async {}

  @override
  Future<void> setFollowedMemberIds(List<String> matrixUserIds) async {}

  @override
  Future<void> setGroupSetting(String key, Object value) async {}

  @override
  Future<void> setAdminIds(List<String> matrixUserIds) async {}

  @override
  Future<void> removeMembers(List<String> matrixUserIds) async {}
}
