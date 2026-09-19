import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/direct_room_directory_convergence.dart';
import 'package:liuhetong_mobile/features/matrix/duplicate_room_registry.dart';
import 'package:matrix/matrix.dart';
import 'matrix_client_factory_test.dart'
    show MatrixTestPaths, SnapshotClient, SnapshotRoom;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 覆盖 m.direct 读写与房间索引的 fake：收敛逻辑只允许通过
/// `setAccountData('m.direct', …)` 改数据，绝不触碰房间成员关系。
final class ConvergenceClient extends SnapshotClient {
  final directory = <String, dynamic>{};
  final roomsById = <String, Room>{};
  final accountWrites = <Map<String, dynamic>>[];
  int leaveCalls = 0;

  @override
  Map<String, dynamic> get directChats => directory;

  @override
  Room? getRoomById(String id) => roomsById[id];

  @override
  Future<void> setAccountData(
      String userId, String type, Map<String, Object?> body) async {
    accountWrites.add(body);
    directory
      ..clear()
      ..addAll(body);
  }
}

SnapshotRoom joinedRoom(ConvergenceClient client, String id,
    {DateTime? activity}) {
  final room = SnapshotRoom(id: id, client: client, joined: true);
  if (activity != null) {
    room.snapshotEvent = Event(
        room: room,
        type: EventTypes.Message,
        eventId: '\$event-$id',
        senderId: '@peer:test',
        originServerTs: activity,
        content: {'body': 'fixture'});
  }
  return room;
}

void main() {
  setUp(() {
    PathProviderPlatform.instance = MatrixTestPaths();
    SharedPreferences.setMockInitialValues({});
  });

  test('canonical 可达时：同 peer 多 joined 房间收敛为单条目（canonical）', () async {
    final client = ConvergenceClient();
    final oldRoom = joinedRoom(client, '!old:test',
        activity: DateTime.utc(2026, 9, 1));
    final canonicalRoom = joinedRoom(client, '!canonical:test',
        activity: DateTime.utc(2026, 9, 18));
    client.roomsById
      ..['!old:test'] = oldRoom
      ..['!canonical:test'] = canonicalRoom;
    client.directory['@peer:test'] = ['!old:test', '!canonical:test'];

    await convergeDirectDirectory(client,
        canonicalRoomIdOf: (_) async => '!canonical:test');

    expect(client.directory['@peer:test'], ['!canonical:test'],
        reason: 'm.direct 必须收敛为服务端 canonical 单条目');
    expect(client.accountWrites.length, 1);
    // 绝不 leave：两个房间仍在本地房间索引里，成员关系未变。
    expect(client.roomsById['!old:test']!.membership, Membership.join);
    expect(client.roomsById['!canonical:test']!.membership, Membership.join);
    expect(client.leaveCalls, 0);
  });

  test('canonical 不可达时：回退本地最新活跃房间，仍收敛为单条目', () async {
    final client = ConvergenceClient();
    client.roomsById
      ..['!stale:test'] = joinedRoom(client, '!stale:test',
          activity: DateTime.utc(2026, 9, 1))
      ..['!fresh:test'] = joinedRoom(client, '!fresh:test',
          activity: DateTime.utc(2026, 9, 18));
    client.directory['@peer:test'] = ['!stale:test', '!fresh:test'];

    await convergeDirectDirectory(client,
        canonicalRoomIdOf: (_) async => throw StateError('offline'));

    expect(client.directory['@peer:test'], ['!fresh:test']);
    expect(client.accountWrites.length, 1);
  });

  test('canonical 指向本地未加入的房间时：不采用，回退本地最新活跃', () async {
    final client = ConvergenceClient();
    client.roomsById
      ..['!stale:test'] = joinedRoom(client, '!stale:test',
          activity: DateTime.utc(2026, 9, 1))
      ..['!fresh:test'] = joinedRoom(client, '!fresh:test',
          activity: DateTime.utc(2026, 9, 18));
    client.directory['@peer:test'] = ['!stale:test', '!fresh:test'];

    await convergeDirectDirectory(client,
        canonicalRoomIdOf: (_) async => '!elsewhere:test');

    expect(client.directory['@peer:test'], ['!fresh:test']);
  });

  test('单房间 peer 与其他 peer 条目保持原样；多 peer 重复合并为一次写入', () async {
    final client = ConvergenceClient();
    client.roomsById
      ..['!a1:test'] = joinedRoom(client, '!a1:test',
          activity: DateTime.utc(2026, 9, 10))
      ..['!a2:test'] = joinedRoom(client, '!a2:test',
          activity: DateTime.utc(2026, 9, 11))
      ..['!b1:test'] = joinedRoom(client, '!b1:test',
          activity: DateTime.utc(2026, 9, 12))
      ..['!b2:test'] = joinedRoom(client, '!b2:test',
          activity: DateTime.utc(2026, 9, 13))
      ..['!solo:test'] = joinedRoom(client, '!solo:test');
    client.directory
      ..['@a:test'] = ['!a1:test', '!a2:test']
      ..['@b:test'] = ['!b1:test', '!b2:test']
      ..['@solo:test'] = ['!solo:test'];

    await convergeDirectDirectory(client);

    expect(client.directory['@a:test'], ['!a2:test']);
    expect(client.directory['@b:test'], ['!b2:test']);
    expect(client.directory['@solo:test'], ['!solo:test'],
        reason: '单房间 peer 不得被触碰');
    expect(client.accountWrites.length, 1, reason: '多 peer 收敛合并为一次 m.direct 写入');
  });

  test('无重复时零写入', () async {
    final client = ConvergenceClient();
    client.roomsById['!solo:test'] = joinedRoom(client, '!solo:test');
    client.directory['@solo:test'] = ['!solo:test'];

    await convergeDirectDirectory(client);

    expect(client.accountWrites, isEmpty);
  });

  test('列表中未加入/已退出的房间不触发收敛，也不被误清理', () async {
    final client = ConvergenceClient();
    client.roomsById['!solo:test'] = joinedRoom(client, '!solo:test');
    // 两个 id 都没有对应的 joined 本地房间（如已退出/未同步）。
    client.directory['@peer:test'] = ['!gone1:test', '!gone2:test'];

    await convergeDirectDirectory(client);

    expect(client.directory['@peer:test'], ['!gone1:test', '!gone2:test'],
        reason: '没有可证明的多 joined 形态时不得改写 m.direct');
    expect(client.accountWrites, isEmpty);
  });

  test('canonical 裁决时把落选房间写入 DuplicateRoomRegistry', () async {
    final client = ConvergenceClient();
    final registry = DuplicateRoomRegistry();
    client.roomsById
      ..['!old:test'] = joinedRoom(client, '!old:test',
          activity: DateTime.utc(2026, 9, 1))
      ..['!canonical:test'] = joinedRoom(client, '!canonical:test',
          activity: DateTime.utc(2026, 9, 18));
    client.directory['@peer:test'] = ['!old:test', '!canonical:test'];

    await convergeDirectDirectory(client,
        registry: registry,
        canonicalRoomIdOf: (_) async => '!canonical:test');

    expect(registry.entries('@me:test').single.duplicateRoomId, '!old:test');
    expect(
        registry.entries('@me:test').single.primaryRoomId, '!canonical:test');
    expect(registry.entries('@me:test').single.peerId, '@peer:test');
  });

  test('canonical 不可达（本地规则裁决）时不登记——弱证据不覆盖权威映射', () async {
    final client = ConvergenceClient();
    final registry = DuplicateRoomRegistry();
    client.roomsById
      ..['!stale:test'] = joinedRoom(client, '!stale:test',
          activity: DateTime.utc(2026, 9, 1))
      ..['!fresh:test'] = joinedRoom(client, '!fresh:test',
          activity: DateTime.utc(2026, 9, 18));
    client.directory['@peer:test'] = ['!stale:test', '!fresh:test'];

    await convergeDirectDirectory(client,
        registry: registry, canonicalRoomIdOf: (_) async => null);

    expect(registry.entries('@me:test'), isEmpty,
        reason: '本地活跃度裁决不是 canonical，登记簿只认服务端权威映射');
  });
}
