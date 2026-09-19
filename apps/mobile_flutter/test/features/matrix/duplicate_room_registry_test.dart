import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/duplicate_room_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('登记后可按 peer 查询 primary room', () async {
    final registry = DuplicateRoomRegistry();
    await registry.record(
      accountId: '@me:test',
      peerId: '@peer:test',
      primaryRoomId: '!canonical:test',
      duplicateRoomId: '!orphan:test',
    );
    expect(
        registry.primaryRoomIdForPeer('@me:test', '@peer:test'),
        '!canonical:test');
    expect(registry.entries('@me:test').single.duplicateRoomId, '!orphan:test');
    expect(registry.entries('@me:test').single.primaryRoomId, '!canonical:test');
    expect(registry.entries('@me:test').single.peerId, '@peer:test');
    expect(registry.entries('@me:test').single.detectedAt, isNotNull);
  });

  test('登记簿按账号隔离', () async {
    final registry = DuplicateRoomRegistry();
    await registry.record(
        accountId: '@a:test',
        peerId: '@peer:test',
        primaryRoomId: '!a-canonical:test',
        duplicateRoomId: '!a-orphan:test');
    expect(registry.primaryRoomIdForPeer('@b:test', '@peer:test'), isNull);
    expect(registry.entries('@b:test'), isEmpty);
  });

  test('登记持久化：新实例（模拟重启）加载后查询结果一致', () async {
    SharedPreferences.setMockInitialValues({});
    final registry = DuplicateRoomRegistry();
    await registry.record(
        accountId: '@me:test',
        peerId: '@peer:test',
        primaryRoomId: '!canonical:test',
        duplicateRoomId: '!orphan:test');

    final restarted = DuplicateRoomRegistry();
    await restarted.ensureLoaded('@me:test');
    expect(restarted.primaryRoomIdForPeer('@me:test', '@peer:test'),
        '!canonical:test');
  });

  test('同 primary 的重复房间登记为条目集合，primary 查询稳定', () async {
    final registry = DuplicateRoomRegistry();
    await registry.record(
        accountId: '@me:test',
        peerId: '@peer:test',
        primaryRoomId: '!keep:test',
        duplicateRoomId: '!dup1:test');
    await registry.record(
        accountId: '@me:test',
        peerId: '@peer:test',
        primaryRoomId: '!keep:test',
        duplicateRoomId: '!dup2:test');
    expect(registry.primaryRoomIdForPeer('@me:test', '@peer:test'), '!keep:test');
    expect(registry.entries('@me:test').length, 2);
  });

  test('登记数量有上限（防无限膨胀），最旧的先被淘汰', () async {
    final registry = DuplicateRoomRegistry(cap: 3);
    for (var i = 0; i < 5; i++) {
      await registry.record(
          accountId: '@me:test',
          peerId: '@peer:$i:test',
          primaryRoomId: '!keep:$i:test',
          duplicateRoomId: '!dup:$i:test');
    }
    final peers = registry
        .entries('@me:test')
        .map((entry) => entry.peerId)
        .toSet();
    expect(peers.contains('@peer:0:test'), isFalse, reason: '最旧的登记被淘汰');
    expect(registry.entries('@me:test').length, 3);
  });
}
