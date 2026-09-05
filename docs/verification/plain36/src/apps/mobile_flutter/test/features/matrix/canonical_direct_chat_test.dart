import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_controller.dart';

/// Canonical Direct Conversation（好友系统重构 Phase E）：
/// 创建私聊前先查规范房间复用；不存在才 inner 新建并注册；
/// 并发冲突采用规范房间；目录异常回落 inner。
void main() {
  const room = DirectChatRoom(
    roomId: '!canonical:test',
    encrypted: true,
    joinedMemberCount: 2,
    participantIds: {'@me:test', '@bob:test'},
  );

  DirectChatRoom roomWithId(String id) => DirectChatRoom(
        roomId: id,
        encrypted: true,
        joinedMemberCount: 2,
        participantIds: const {'@me:test', '@bob:test'},
      );

  test('规范房间存在 → 直接复用，不触发 inner 新建', () async {
    var innerCalls = 0;
    var opened = <String>[];
    final gateway = CanonicalDirectChatGateway(
      inner: _FakeInnerGateway(() async {
        innerCalls++;
        return roomWithId('!fresh:test');
      }),
      directory: _FakeDirectory(canonical: '!canonical:test'),
      businessUserIdOf: (mxid) => 'bob-id',
      openExistingRoom: (roomId) async {
        opened.add(roomId);
        return roomWithId(roomId);
      },
    );

    final result = await gateway.openOrCreateDirectChat('@bob:test');

    expect(result.roomId, '!canonical:test');
    expect(opened, ['!canonical:test']);
    expect(innerCalls, 0, reason: '有规范房间时禁止再新建');
  });

  test('无规范房间 → inner 新建并注册，返回新房间', () async {
    var registered = <String>[];
    final gateway = CanonicalDirectChatGateway(
      inner: _FakeInnerGateway(() async => roomWithId('!fresh:test')),
      directory: _FakeDirectory(canonical: null)
        ..onRegister = (peer, roomId) async {
          registered.add('$peer:$roomId');
          return roomId;
        },
      businessUserIdOf: (mxid) => 'bob-id',
      openExistingRoom: (roomId) async => roomWithId(roomId),
    );

    final result = await gateway.openOrCreateDirectChat('@bob:test');

    expect(result.roomId, '!fresh:test');
    expect(registered, ['bob-id:!fresh:test']);
  });

  test('并发冲突（注册返回既有房间）→ 弃用本次房间采用规范房间', () async {
    final gateway = CanonicalDirectChatGateway(
      inner: _FakeInnerGateway(() async => roomWithId('!fresh:test')),
      directory: _FakeDirectory(canonical: null)
        ..onRegister = (peer, roomId) async => '!winner:test',
      businessUserIdOf: (mxid) => 'bob-id',
      openExistingRoom: (roomId) async => roomWithId(roomId),
    );

    final result = await gateway.openOrCreateDirectChat('@bob:test');
    expect(result.roomId, '!winner:test');
  });

  test('目录查询异常 → 静默回落 inner 新建', () async {
    final gateway = CanonicalDirectChatGateway(
      inner: _FakeInnerGateway(() async => roomWithId('!fresh:test')),
      directory: _ThrowingDirectory(),
      businessUserIdOf: (mxid) => 'bob-id',
      openExistingRoom: (roomId) async => roomWithId(roomId),
    );
    final result = await gateway.openOrCreateDirectChat('@bob:test');
    expect(result.roomId, '!fresh:test');
  });

  test('注册冲突且规范房间已失效（如对端退出）→ 回退本次新建房间，不抛错', () async {
    // 真机 BUG 场景：direct_conversations 里登记的旧房间已不可用，
    // 依既有房间打开抛错必须回退到本次新建的有效房间，禁止死锁报错。
    var openAttempts = <String>[];
    final gateway = CanonicalDirectChatGateway(
      inner: _FakeInnerGateway(() async => roomWithId('!fresh:test')),
      directory: _FakeDirectory(canonical: null)
        ..onRegister = (peer, roomId) async => '!dead:test',
      businessUserIdOf: (mxid) => 'bob-id',
      openExistingRoom: (roomId) async {
        openAttempts.add(roomId);
        throw StateError('peer left');
      },
    );

    final result = await gateway.openOrCreateDirectChat('@bob:test');
    expect(result.roomId, '!fresh:test');
    expect(openAttempts, ['!dead:test']);
  });

  test('无业务 userId（非好友映射缺失）→ 直接 inner', () async {
    var directoryQueried = false;
    final gateway = CanonicalDirectChatGateway(
      inner: _FakeInnerGateway(() async => room),
      directory: _FakeDirectory(canonical: '!canonical:test')
        ..onQuery = (_) => directoryQueried = true,
      businessUserIdOf: (mxid) => null,
      openExistingRoom: (roomId) async => roomWithId(roomId),
    );
    final result = await gateway.openOrCreateDirectChat('@stranger:test');
    expect(result.roomId, '!canonical:test');
    expect(directoryQueried, isFalse, reason: '业务映射缺失时不得查询目录');
  });
}

final class _FakeInnerGateway implements DirectChatGateway {
  _FakeInnerGateway(this.open);
  final Future<DirectChatRoom> Function() open;

  @override
  Future<DirectChatRoom> openOrCreateDirectChat(String matrixUserId) => open();
}

final class _FakeDirectory implements CanonicalDirectRoomDirectory {
  _FakeDirectory({this.canonical});

  final String? canonical;
  bool Function(String peer)? onQuery;
  Future<String?> Function(String peer, String roomId)? onRegister;

  @override
  Future<String?> canonicalRoomId(String peerUserId) async {
    onQuery?.call(peerUserId);
    return canonical;
  }

  @override
  Future<String?> registerRoom(String peerUserId, String roomId) async =>
      onRegister?.call(peerUserId, roomId) ?? roomId;
}

final class _ThrowingDirectory implements CanonicalDirectRoomDirectory {
  @override
  Future<String?> canonicalRoomId(String peerUserId) async =>
      throw StateError('offline');

  @override
  Future<String?> registerRoom(String peerUserId, String roomId) async =>
      throw StateError('offline');
}
