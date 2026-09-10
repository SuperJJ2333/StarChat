import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_direct_chat_adapter.dart';

/// 问题三：规范私聊房间打开时，本地成员/加密状态可能尚未同步送达
/// （首屏同步滞后、新设备恢复）。此前 openCanonicalRoom 校验失败立即
/// 抛错，上层回落新建第二个私聊房间，造成“重复会话”。
/// 修复后必须：等待状态收敛、读取服务端成员并重邀；暂不可用时抛错
/// 保留原房间重试，不因状态延迟或失败回落新建。
void main() {
  test('服务端确认三人房间，不能被后续旧双人缓存覆盖并当作私聊打开', () async {
    final client = _ReadinessClient()
      ..serverIds = ['@self:test', '@friend:test', '@third:test'];
    client.room.participantSets = [
      ['@self:test'],
      ['@self:test'],
      ['@self:test', '@friend:test'],
    ];
    await expectLater(
        MatrixDirectChatBackend(client)
            .openCanonicalRoom(client.room.id, matrixUserId: '@friend:test'),
        throwsStateError);
    expect(client.room.invites, isEmpty);
  });
  test('规范目录传入好友ID，m.direct缺失且对方已退出也能重邀原好友', () async {
    final client = _CachedMembersClient();
    client.room.peer = null;
    final result = await MatrixDirectChatBackend(client)
        .openCanonicalRoom(client.room.id, matrixUserId: '@friend:test');
    expect(result.participantIds, {'@self:test', '@friend:test'});
    expect(client.room.invites, ['@friend:test']);
  });

  test('过期m.direct指向其他人，不能对该人重邀或打开错误房间', () async {
    final client = _ReadinessClient();
    client.room.peer = '@wrong:test';
    final result = await MatrixDirectChatBackend(client)
        .openCanonicalRoom(client.room.id, matrixUserId: '@friend:test');
    expect(result.participantIds, {'@self:test', '@friend:test'});
    expect(client.room.invites, isEmpty);
  });
  test('SDK缓存仍为单人，服务端重邀成功后读取新成员并打开原房间', () async {
    final client = _CachedMembersClient();
    final result =
        await MatrixDirectChatBackend(client).openCanonicalRoom(client.room.id);
    expect(result.participantIds, {'@self:test', '@friend:test'});
    expect(client.room.invites, ['@friend:test']);
    expect(client.memberReads, greaterThanOrEqualTo(2));
  });
  test('成员状态尚未同步：等待收敛后复用规范房间，不新建', () async {
    final client = _ReadinessClient();
    // 前几次成员查询只返回自己（模拟 m.room.member/encryption 尚未同步），
    // 之后收敛为双人。
    client.room.participantSets = [
      ['@self:test'],
      ['@self:test'],
      ['@self:test', '@friend:test'],
    ];
    final room =
        await MatrixDirectChatBackend(client).openCanonicalRoom(client.room.id);
    expect(room.roomId, client.room.id);
    expect(room.participantIds, contains('@friend:test'));
    expect(client.room.invites, isEmpty, reason: '成员只是迟到而非退出，无需重邀');
  });

  test('对方已退出：等待后仍单人，经重邀修复复用同一房间', () async {
    final client = _ReadinessClient();
    client.room.participantSets = [
      ['@self:test'],
      ['@self:test'],
      ['@self:test'],
    ];
    // invite 成功后成员恢复双人（对端重新受邀，经邀请扫描自动加入）。
    client.room.afterInviteParticipants = ['@self:test', '@friend:test'];
    final room =
        await MatrixDirectChatBackend(client).openCanonicalRoom(client.room.id);
    expect(room.roomId, client.room.id);
    expect(client.room.invites, ['@friend:test'], reason: '必须重邀对方而不是新建房间');
  });

  test('重邀后仍单人：有界失败，保留原房间重试', () async {
    final client = _ReadinessClient();
    client.room.participantSets = [
      ['@self:test'],
      ['@self:test'],
      ['@self:test'],
    ];
    client.room.afterInviteParticipants = null; // 重邀后仍单人
    await expectLater(
      MatrixDirectChatBackend(client).openCanonicalRoom(client.room.id),
      throwsStateError,
    );
    expect(client.room.invites, ['@friend:test'], reason: '已经尝试恢复原房间');
  });
}

final class _CachedMembersClient extends _ReadinessClient {
  _CachedMembersClient() {
    room.participantSets = [
      ['@self:test']
    ];
  }
  int memberReads = 0;

  @override
  Future<List<MatrixEvent>?> getMembersByRoom(String roomId,
      {String? at, Membership? membership, Membership? notMembership}) async {
    memberReads++;
    return [
      for (final id in [
        '@self:test',
        if (room.invites.isNotEmpty) '@friend:test'
      ])
        MatrixEvent.fromJson({
          'type': EventTypes.RoomMember,
          'state_key': id,
          'sender': '@self:test',
          'event_id': '\$member-$memberReads-$id',
          'origin_server_ts': 1,
          'content': {'membership': id == '@self:test' ? 'join' : 'invite'},
        }),
    ];
  }
}

final class _ReadinessClient extends Fake implements Client {
  List<String>? serverIds;
  late _ReadinessRoom room = _ReadinessRoom(this);
  final Map<String, List<String>> directChatMap = {};

  @override
  String get userID => '@self:test';

  @override
  Room? getRoomById(String id) => room;

  @override
  Map<String, List<String>> get directChats => directChatMap;

  @override
  Future<List<MatrixEvent>?> getMembersByRoom(String roomId,
      {String? at, Membership? membership, Membership? notMembership}) async {
    return [
      for (final user in serverIds == null
          ? await room.requestParticipants()
          : [
              for (final id in serverIds!)
                User(id, membership: 'join', room: room)
            ])
        MatrixEvent.fromJson({
          'type': EventTypes.RoomMember,
          'state_key': user.id,
          'sender': '@self:test',
          'event_id': '\$member-${user.id}',
          'origin_server_ts': 1,
          'content': {'membership': user.membership.name},
        }),
    ];
  }

  @override
  Future<void> setAccountData(
      String userId, String type, Map<String, Object?> content) async {}

  @override
  Future<SyncUpdate> waitForRoomInSync(String roomId,
      {bool join = false, bool invite = false, bool leave = false}) async {
    return SyncUpdate.fromJson({});
  }

  @override
  Future<String> joinRoomById(String roomId,
      {String? reason, ThirdPartySigned? thirdPartySigned}) async {
    return roomId;
  }
}

final class _ReadinessRoom extends Room {
  _ReadinessRoom(Client client) : super(id: '!canonical:test', client: client);

  @override
  Membership get membership => Membership.join;

  /// 每次 requestParticipants 依次返回一组；耗尽后停留在最后一组。
  List<List<String>> participantSets = [
    ['@self:test', '@friend:test']
  ];
  List<String>? afterInviteParticipants;
  final List<String> invites = [];
  String? peer = '@friend:test';

  @override
  bool get encrypted => true;

  @override
  bool get isDirectChat => true;

  @override
  String? get directChatMatrixID => peer;

  @override
  Future<List<User>> requestParticipants(
      [List<Membership> membershipFilter = const [
        Membership.join,
        Membership.invite,
        Membership.knock
      ],
      bool suppressWarning = false,
      bool cache = true]) async {
    if (participantSets.length > 1) participantSets.removeAt(0);
    var ids = participantSets.first;
    if (invites.isNotEmpty && afterInviteParticipants != null) {
      ids = afterInviteParticipants!;
    }
    return [
      for (final id in ids) User(id, membership: 'join', room: this),
    ];
  }

  @override
  Future<void> invite(String userID, {String? reason}) async {
    invites.add(userID);
  }
}
