import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_controller.dart';

/// Canonical Direct Conversation（好友系统重构 Phase E）：
/// 创建私聊前先查规范房间复用；不存在才 inner 新建并注册；
/// 并发注册采用规范房间；目录异常禁止回落。跨端创建使用独立协调网关。
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

  test('目录查询异常 → 禁止回落新建', () async {
    final gateway = CanonicalDirectChatGateway(
      inner: _FakeInnerGateway(() async => roomWithId('!fresh:test')),
      directory: _ThrowingDirectory(),
      businessUserIdOf: (mxid) => 'bob-id',
      openExistingRoom: (roomId) async => roomWithId(roomId),
    );
    await expectLater(
        gateway.openOrCreateDirectChat('@bob:test'), throwsStateError);
  });

  test('注册冲突且规范房间不可用 → 报错，不返回第二个房间', () async {
    // 旧房间暂不可用并不授权返回第二个房间；等待原房间恢复。
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

    await expectLater(
        gateway.openOrCreateDirectChat('@bob:test'), throwsStateError);
    expect(openAttempts, ['!dead:test']);
  });

  test('无业务 userId（非好友映射缺失）→ 禁止新建', () async {
    var directoryQueried = false;
    final gateway = CanonicalDirectChatGateway(
      inner: _FakeInnerGateway(() async => room),
      directory: _FakeDirectory(canonical: '!canonical:test')
        ..onQuery = (_) => directoryQueried = true,
      businessUserIdOf: (mxid) => null,
      openExistingRoom: (roomId) async => roomWithId(roomId),
    );
    await expectLater(
        gateway.openOrCreateDirectChat('@stranger:test'), throwsStateError);
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
