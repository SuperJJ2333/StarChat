import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_controller.dart';

final class FakeDirectChatBackend implements DirectChatBackend {
  DirectChatRoom? existing;
  var creates = 0;
  var failCreate = false;
  String lastMatrixUserId = '@alice:example.test';
  String? lastAvoidRoomId;
  DirectChatRoom? repairResult;
  var repairs = 0;
  var gateCreate = false;
  final createStarted = Completer<void>();
  final allowCreate = Completer<void>();

  @override
  Future<DirectChatRoom?> findJoinedDirectRoom(String matrixUserId) async =>
      existing;

  @override
  Future<DirectChatRoom?> repairDirectRoom(
    DirectChatRoom room,
    String matrixUserId,
  ) async {
    repairs++;
    return repairResult;
  }

  @override
  Future<String> createEncryptedDirectRoom(
    String matrixUserId, {
    String? avoidRoomId,
  }) async {
    lastMatrixUserId = matrixUserId;
    lastAvoidRoomId = avoidRoomId;
    creates++;
    if (!createStarted.isCompleted) createStarted.complete();
    if (failCreate) throw StateError('offline');
    if (gateCreate) await allowCreate.future;
    return '!new:example.test';
  }

  @override
  Future<DirectChatRoom> waitForRoom(String roomId) async => DirectChatRoom(
        roomId: roomId,
        encrypted: true,
        joinedMemberCount: 2,
        participantIds: {'@me:example.test', lastMatrixUserId},
      );
}

void main() {
  test('reuses an encrypted two-person m.direct room', () async {
    final backend = FakeDirectChatBackend()
      ..existing = const DirectChatRoom(
        roomId: '!existing:example.test',
        encrypted: true,
        joinedMemberCount: 2,
        participantIds: {'@me:example.test', '@alice:example.test'},
      );
    final room = await DirectChatService(backend)
        .openOrCreateDirectChat('@alice:example.test');
    expect(room.roomId, '!existing:example.test');
    expect(backend.creates, 0);
  });

  test('creates and verifies a new encrypted two-person direct room', () async {
    final backend = FakeDirectChatBackend();
    final opening = DirectChatService(backend)
        .openOrCreateDirectChat('@alice:example.test');
    await backend.createStarted.future;
    backend.allowCreate.complete();
    final room = await opening;
    expect(room.encrypted, isTrue);
    expect(room.joinedMemberCount, 2);
    expect(backend.creates, 1);
  });

  test('double tap shares one creation and failure can retry', () async {
    final backend = FakeDirectChatBackend()..failCreate = true;
    final controller = DirectChatController(DirectChatService(backend));
    final first = controller.open('@alice:example.test');
    final second = controller.open('@alice:example.test');
    await expectLater(first, throwsStateError);
    await expectLater(second, throwsStateError);
    expect(backend.creates, 1);
    expect(controller.state, DirectChatState.failed);

    backend.failCreate = false;
    backend.allowCreate.complete();
    final room = await controller.retry();
    expect(room.roomId, '!new:example.test');
    expect(controller.state, DirectChatState.ready);
    expect(backend.creates, 2);
  });

  test('different contacts never share an in-flight room future', () async {
    final gateway = PerContactGateway();
    final controller = DirectChatController(gateway);
    final alice = controller.open('@alice:example.test');
    final bob = controller.open('@bob:example.test');

    gateway.complete('@bob:example.test');
    gateway.complete('@alice:example.test');
    expect((await alice).roomId, '!alice:example.test');
    expect((await bob).roomId, '!bob:example.test');
    expect(gateway.opens, ['@alice:example.test', '@bob:example.test']);
  });

  test('对方已退出的旧私聊：重新邀请并复用同一房间（不新建）', () async {
    // 真机 BUG：superJJ 与好友的 DM 中对方 invite→leave，_requireSafe
    // 直接抛"无法打开加密会话"。修复后应重邀对方恢复会话（保留历史）。
    final backend = FakeDirectChatBackend()
      ..existing = const DirectChatRoom(
        roomId: '!stale:example.test',
        encrypted: true,
        joinedMemberCount: 1,
        participantIds: {'@me:example.test'},
      )
      ..repairResult = const DirectChatRoom(
        roomId: '!stale:example.test',
        encrypted: true,
        joinedMemberCount: 2,
        participantIds: {'@me:example.test', '@alice:example.test'},
      );
    final room = await DirectChatService(backend)
        .openOrCreateDirectChat('@alice:example.test');
    expect(room.roomId, '!stale:example.test');
    expect(backend.repairs, 1);
    expect(backend.creates, 0);
  });

  test('对方退出且重邀失败：绕开坏房间显式新建', () async {
    final backend = FakeDirectChatBackend()
      ..existing = const DirectChatRoom(
        roomId: '!stale:example.test',
        encrypted: true,
        joinedMemberCount: 1,
        participantIds: {'@me:example.test'},
      ); // repairResult 为 null：修复失败
    final room = await DirectChatService(backend)
        .openOrCreateDirectChat('@alice:example.test');
    expect(room.roomId, '!new:example.test');
    expect(backend.lastAvoidRoomId, '!stale:example.test');
    expect(backend.creates, 1);
  });

  test('未加密双人房间：补开加密后复用同一房间', () async {
    final backend = FakeDirectChatBackend()
      ..existing = const DirectChatRoom(
        roomId: '!plain:example.test',
        encrypted: false,
        joinedMemberCount: 2,
        participantIds: {'@me:example.test', '@alice:example.test'},
      )
      ..repairResult = const DirectChatRoom(
        roomId: '!plain:example.test',
        encrypted: true,
        joinedMemberCount: 2,
        participantIds: {'@me:example.test', '@alice:example.test'},
      );
    final room = await DirectChatService(backend)
        .openOrCreateDirectChat('@alice:example.test');
    expect(room.roomId, '!plain:example.test');
    expect(backend.creates, 0);
  });

  test('三个成员的异常房间：不可修复则显式新建', () async {
    final backend = FakeDirectChatBackend()
      ..existing = const DirectChatRoom(
        roomId: '!unsafe:example.test',
        encrypted: false,
        joinedMemberCount: 3,
        participantIds: {
          '@me:example.test',
          '@alice:example.test',
          '@mallory:example.test'
        },
      );
    final room = await DirectChatService(backend)
        .openOrCreateDirectChat('@alice:example.test');
    expect(room.roomId, '!new:example.test');
    expect(backend.lastAvoidRoomId, '!unsafe:example.test');
  });

  test('不含目标的双人房间：不可修复则显式新建', () async {
    final backend = FakeDirectChatBackend()
      ..existing = const DirectChatRoom(
        roomId: '!wrong:example.test',
        encrypted: true,
        joinedMemberCount: 2,
        participantIds: {'@me:example.test', '@mallory:example.test'},
      );
    final room = await DirectChatService(backend)
        .openOrCreateDirectChat('@alice:example.test');
    expect(room.roomId, '!new:example.test');
    expect(backend.lastAvoidRoomId, '!wrong:example.test');
  });
}

final class PerContactGateway implements DirectChatGateway {
  final opens = <String>[];
  final pending = <String, Completer<DirectChatRoom>>{};

  @override
  Future<DirectChatRoom> openOrCreateDirectChat(String matrixUserId) {
    opens.add(matrixUserId);
    return (pending[matrixUserId] = Completer<DirectChatRoom>()).future;
  }

  void complete(String matrixUserId) {
    final localpart = matrixUserId.substring(1, matrixUserId.indexOf(':'));
    pending[matrixUserId]!.complete(DirectChatRoom(
      roomId: '!$localpart:example.test',
      encrypted: true,
      joinedMemberCount: 2,
      participantIds: {'@me:example.test', matrixUserId},
    ));
  }
}
