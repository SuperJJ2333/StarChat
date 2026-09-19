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
}
