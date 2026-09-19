import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/direct_room_directory_convergence.dart';
import 'package:liuhetong_mobile/features/matrix/duplicate_room_registry.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'matrix_client_factory_test.dart' show MatrixTestPaths, SnapshotClient;

/// 真实 SDK 身份链路组合测试（用户要求第六节）：
/// Room 的 isDirectChat/directChatMatrixID 一律由**真实 SDK 代码**从
/// client.directChats（m.direct）计算，禁止固定 isDirectChat 替身。
/// 链路：来源关联同步（保留 m.direct；含 matrix→业务 ID 转换）→ snapshot → 打开房间。
final class IdentityFlowClient extends SnapshotClient {
  /// 真实 m.direct 目录：Room.directChatMatrixID 由此计算。
  final directory = <String, dynamic>{};
  final roomsById = <String, Room>{};
  final accountWrites = <Map<String, dynamic>>[];

  @override
  Map<String, dynamic> get directChats => directory;

  @override
  List<Room> get rooms => roomsById.values.toList(growable: false);

  @override
  Room? getRoomById(String id) => roomsById[id];

  @override
  Future<void> setAccountData(
      String userId, String type, Map<String, Object?> body) async {
    accountWrites.add(body);
    accountData[type] = BasicEvent(type: type, content: body);
    if (type == 'm.direct') {
      directory
        ..clear()
        ..addAll(body);
    }
  }
}

/// 只覆写加密标志与时间线载体（非身份字段）；isDirectChat 走真实计算。
final class IdentityFlowRoom extends Room {
  IdentityFlowRoom({
    required super.client,
    required super.id,
    super.membership,
    super.summary,
  }) {
    for (final userId in ['@me:test', '@peer:test']) {
      setState(Event(
          room: this,
          type: EventTypes.RoomMember,
          eventId: 'member-$userId',
          senderId: userId,
          stateKey: userId,
          originServerTs: DateTime.utc(2026, 9, 19),
          content: {'membership': 'join', 'displayname': userId}));
    }
  }
  @override
  bool get encrypted => true;
  @override
  Future<Timeline> getTimeline(
          {void Function(int)? onChange,
          void Function(int)? onRemove,
          void Function(int)? onInsert,
          void Function()? onNewEvent,
          void Function()? onUpdate,
          String? eventContextId}) async =>
      _StubTimeline();
}

final class _StubTimeline extends Fake implements Timeline {
  @override
  bool get canRequestHistory => false;
  @override
  bool get isFragmentedTimeline => false;
  @override
  bool get canRequestFuture => false;
  @override
  Future<void> setReadMarker({String? eventId, bool? public}) async {}
}

Room _joinedRealRoom(IdentityFlowClient client, String id) => IdentityFlowRoom(
      client: client,
      id: id,
      membership: Membership.join,
      summary: RoomSummary.fromJson({
        'm.joined_member_count': 2,
        'm.invited_member_count': 0,
        'm.heroes': [],
      }),
    );

final class MutableRoomsClient extends IdentityFlowClient {
  final liveRooms = <Room>[];
  @override
  List<Room> get rooms => liveRooms;
}

final class HydratingIdentityRoom extends IdentityFlowRoom {
  HydratingIdentityRoom(
      {required super.client, required super.id, required this.onHydrate})
      : super(membership: Membership.join);
  final void Function() onHydrate;
  @override
  Future<void> postLoad() async {
    onHydrate();
    partial = false;
  }
}

final class MemberDatabaseClient extends IdentityFlowClient {
  final stored = MemberDatabase();
  @override
  DatabaseApi get database => stored;
}

final class MemberDatabase extends Fake implements DatabaseApi {
  int reads = 0;
  @override
  Future<List<User>> getUsers(Room room) async {
    reads++;
    return [User('@third:test', room: room, membership: 'join')];
  }
}

void main() {
  setUp(() {
    PathProviderPlatform.instance = MatrixTestPaths();
    SharedPreferences.setMockInitialValues({});
  });

  test('项1：收敛的 canonical 查询必须用业务 userId（matrixId 经转换）', () async {
    final client = IdentityFlowClient();
    final registry = DuplicateRoomRegistry();
    client.roomsById
      ..['!old:test'] = _joinedRealRoom(client, '!old:test')
      ..['!new:test'] = _joinedRealRoom(client, '!new:test');
    client.directory['@peer:test'] = ['!old:test', '!new:test'];

    final businessLookups = <String>[];
    await convergeDirectDirectory(
      client,
      registry: registry,
      businessUserIdOf: (matrixPeer) => matrixPeer,
      canonicalRoomIdOf: (businessUserId) async {
        businessLookups.add(businessUserId);
        return '!new:test';
      },
    );

    expect(businessLookups, ['@peer:test'],
        reason: '转换器把 m.direct 键（matrixId）交给查询方');
    expect(client.directory['@peer:test'], ['!old:test', '!new:test']);
    // 登记簿按 matrixId 记 peer（与解析器 directPeerId 同一口径）。
    expect(
        registry.primaryRoomIdForPeer('@me:test', '@peer:test'), '!new:test');
    expect(registry.entryForRoom('@me:test', '!old:test'), isNotNull);
  });

  test('项1：业务身份缺失（转换返回空）时跳过 canonical 查询，只走本地规则', () async {
    final client = IdentityFlowClient();
    var lookups = 0;
    client.roomsById
      ..['!old:test'] = _joinedRealRoom(client, '!old:test')
      ..['!new:test'] = _joinedRealRoom(client, '!new:test');
    client.directory['@peer:test'] = ['!old:test', '!new:test'];

    await convergeDirectDirectory(
      client,
      businessUserIdOf: (_) => '',
      canonicalRoomIdOf: (businessUserId) async {
        lookups++;
        return null;
      },
    );

    expect(lookups, 0, reason: '无法映射到业务身份时不得用 matrixId 误查目录');
  });

  test('项2：历史来源保留 m.direct 身份但只呈现一个逻辑会话', () async {
    final client = IdentityFlowClient();
    final registry = DuplicateRoomRegistry();
    final loser = _joinedRealRoom(client, '!old:test');
    client.roomsById
      ..['!old:test'] = loser
      ..['!new:test'] = _joinedRealRoom(client, '!new:test');
    client.directory['@peer:test'] = ['!old:test', '!new:test'];

    await convergeDirectDirectory(
      client,
      registry: registry,
      businessUserIdOf: (_) => 'peer-biz',
      canonicalRoomIdOf: (_) async => '!new:test',
    );
    expect(loser.isDirectChat, isTrue, reason: '历史来源保留真实 SDK 私聊身份');

    final matrix = MatrixSdkE2eeClient(
      client,
      homeserver: Uri.parse('https://test'),
      duplicateRooms: registry,
    );
    final snapshot = await matrix.conversations.snapshot();

    expect(snapshot.rooms.map((room) => room.id).toList(), ['!new:test'],
        reason: '旧房间经登记簿重新关联身份后继续隐藏，绝不以普通房间重现');
    expect(snapshot.rooms.single.isDirect, isTrue);
    expect(snapshot.rooms.single.directPeerId, '@peer:test');
  });

  test('项6：真实 SDK 身份 → 收敛 → snapshot 唯一 → 打开房间，全链路', () async {
    final client = IdentityFlowClient();
    final registry = DuplicateRoomRegistry();
    client.roomsById
      ..['!old:test'] = _joinedRealRoom(client, '!old:test')
      ..['!new:test'] = _joinedRealRoom(client, '!new:test');
    client.directory['@peer:test'] = ['!old:test', '!new:test'];

    await convergeDirectDirectory(
      client,
      registry: registry,
      businessUserIdOf: (_) => 'peer-biz',
      canonicalRoomIdOf: (_) async => '!new:test',
    );
    final matrix = MatrixSdkE2eeClient(
      client,
      homeserver: Uri.parse('https://test'),
      duplicateRooms: registry,
    );
    final snapshot = await matrix.conversations.snapshot();
    expect(snapshot.rooms, hasLength(1));

    final lease = await matrix.openRoomLease('!new:test');
    await lease.openRoomTimeline(onUpdate: () {});
    expect(lease.roomInfo.id, '!new:test');
    expect(lease.roomInfo.isDirect, isTrue,
        reason: '打开的是逻辑会话的 primary 房间，身份来自真实 SDK 计算');
  });
  test(
      'unknown rooms wait for identity instead of flashing duplicate group rows',
      () async {
    final client = IdentityFlowClient();
    client.roomsById
      ..['!old:test'] = _joinedRealRoom(client, '!old:test')
      ..['!new:test'] = _joinedRealRoom(client, '!new:test');
    final registry = DuplicateRoomRegistry();
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'), duplicateRooms: registry);
    final pending = await matrix.conversations.snapshot();
    expect(pending.rooms, isEmpty);
    expect(pending.unresolvedRoomCount, 2);
    expect(client.rooms, hasLength(2),
        reason: 'quarantine must not delete room history');
    await registry.rememberPrimary('@me:test', '@peer:test', '!new:test');
    await registry.record(
        accountId: '@me:test',
        peerId: '@peer:test',
        primaryRoomId: '!new:test',
        duplicateRoomId: '!old:test');
    final resolved = await matrix.conversations.snapshot();
    expect(resolved.rooms.map((r) => r.id), ['!new:test']);
    expect(resolved.unresolvedRoomCount, 0);
    expect(client.accountWrites, isEmpty,
        reason: 'projection must be local with no Matrix writes');
  });

  test(
      'observed direct identity survives m.direct removal and process restart offline',
      () async {
    final client = IdentityFlowClient();
    client.roomsById
      ..['!old:test'] = _joinedRealRoom(client, '!old:test')
      ..['!new:test'] = _joinedRealRoom(client, '!new:test');
    client.directory['@peer:test'] = ['!old:test', '!new:test'];
    final first = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'),
        duplicateRooms: DuplicateRoomRegistry());
    expect((await first.conversations.snapshot()).rooms, hasLength(1));
    client.directory.clear();
    final restarted = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'),
        duplicateRooms: DuplicateRoomRegistry());
    final snapshot = await restarted.conversations.snapshot();
    expect(snapshot.rooms, hasLength(1));
    expect(snapshot.rooms.single.directPeerId, '@peer:test');
    expect(restarted.logicalRoomSourcesSync(snapshot.rooms.single.id),
        {'!old:test', '!new:test'},
        reason: 'both histories remain logical sources');
  });

  test('reservation arriving before m.direct resolves from complete pair state',
      () async {
    final client = IdentityFlowClient();
    for (final id in ['!old:test', '!new:test']) {
      final room = _joinedRealRoom(client, id);
      room.partial = false;
      room.setState(Event(
          room: room,
          type: 'com.chatflow.direct_reservation',
          stateKey: '',
          eventId: 'reservation-$id',
          senderId: '@me:test',
          originServerTs: DateTime.utc(2026, 9, 19),
          content: {'reservation_id': 'known'}));
      client.roomsById[id] = room;
    }
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'),
        duplicateRooms: DuplicateRoomRegistry());
    final snapshot = await matrix.conversations.snapshot();
    expect(snapshot.rooms, hasLength(1));
    expect(snapshot.rooms.single.directPeerId, '@peer:test');
  });

  test('two-member legacy app groups remain separate from private chat',
      () async {
    final client = IdentityFlowClient();
    for (final id in ['!group1:test', '!group2:test']) {
      final room = _joinedRealRoom(client, id);
      room.setState(Event(
          room: room,
          type: EventTypes.RoomPowerLevels,
          stateKey: '',
          eventId: 'power-$id',
          senderId: '@me:test',
          originServerTs: DateTime.utc(2026, 9, 19),
          content: {
            'events': {
              'com.changliao.group.settings': 50,
              'com.changliao.group.announcement': 50
            }
          }));
      client.roomsById[id] = room;
    }
    client.roomsById['!direct:test'] = _joinedRealRoom(client, '!direct:test');
    client.directory['@peer:test'] = ['!direct:test'];
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'),
        duplicateRooms: DuplicateRoomRegistry());
    final snapshot = await matrix.conversations.snapshot();
    expect(snapshot.rooms, hasLength(3));
    expect(snapshot.rooms.where((r) => !r.isDirect).map((r) => r.id).toSet(),
        {'!group1:test', '!group2:test'});
  });

  test('sync may add a room while lazy local identity is being hydrated',
      () async {
    final client = MutableRoomsClient();
    client.liveRooms.add(HydratingIdentityRoom(
        client: client,
        id: '!pending:test',
        onHydrate: () =>
            client.liveRooms.add(_joinedRealRoom(client, '!later:test'))));
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'),
        duplicateRooms: DuplicateRoomRegistry());
    final first = await matrix.conversations.snapshot();
    expect(first.rooms, isEmpty);
    expect(first.unresolvedRoomCount, 1);
    expect((await matrix.conversations.snapshot()).unresolvedRoomCount, 2);
  });
  test('identity becoming contradictory during local hydration stays pending',
      () async {
    final client = MutableRoomsClient();
    client.directory['@peer:test'] = ['!first:test'];
    client.liveRooms.add(_joinedRealRoom(client, '!first:test'));
    client.liveRooms.add(HydratingIdentityRoom(
        client: client,
        id: '!pending:test',
        onHydrate: () => client.directory['@other:test'] = ['!first:test']));
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'),
        duplicateRooms: DuplicateRoomRegistry());
    final snapshot = await matrix.conversations.snapshot();
    expect(snapshot.rooms, isEmpty);
    expect(snapshot.unresolvedRoomCount, 2);
  });
  test(
      'legacy multiparty group hydrates member store locally even when partial is false',
      () async {
    final client = MemberDatabaseClient();
    final legacy = IdentityFlowRoom(
        client: client,
        id: '!legacy:test',
        membership: Membership.join,
        summary: RoomSummary.fromJson(
            {'m.joined_member_count': 3, 'm.invited_member_count': 0}));
    legacy.partial = false;
    client.roomsById[legacy.id] = legacy;
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'),
        duplicateRooms: DuplicateRoomRegistry());
    final snapshot = await matrix.conversations.snapshot();
    expect(snapshot.rooms.map((r) => r.id), ['!legacy:test']);
    expect(snapshot.rooms.single.isDirect, isFalse);
    expect(client.stored.reads, 1);
    expect(snapshot.unresolvedRoomCount, 0);
    expect((await matrix.conversations.snapshot()).rooms, hasLength(1));
    expect(client.stored.reads, 1,
        reason: 'retained identity avoids repeated member hydration');
    expect(client.accountWrites, isEmpty);
  });
}
