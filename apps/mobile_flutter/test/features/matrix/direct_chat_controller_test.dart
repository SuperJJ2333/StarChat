import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_controller.dart';

final class FakeDirectChatBackend implements DirectChatBackend {
  DirectChatRoom? existing;
  var creates = 0;
  var failCreate = false;
  final createStarted = Completer<void>();
  final allowCreate = Completer<void>();

  @override
  Future<DirectChatRoom?> findJoinedDirectRoom(String matrixUserId) async =>
      existing;

  @override
  Future<String> createEncryptedDirectRoom(String matrixUserId) async {
    creates++;
    if (!createStarted.isCompleted) createStarted.complete();
    if (failCreate) throw StateError('offline');
    await allowCreate.future;
    return '!new:example.test';
  }

  @override
  Future<DirectChatRoom> waitForRoom(String roomId) async =>
      DirectChatRoom(roomId: roomId, encrypted: true, joinedMemberCount: 2);
}

void main() {
  test('reuses an encrypted two-person m.direct room', () async {
    final backend = FakeDirectChatBackend()
      ..existing = const DirectChatRoom(
        roomId: '!existing:example.test',
        encrypted: true,
        joinedMemberCount: 2,
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

  test('rejects an unencrypted or multi-member room before navigation',
      () async {
    final backend = FakeDirectChatBackend()
      ..existing = const DirectChatRoom(
        roomId: '!unsafe:example.test',
        encrypted: false,
        joinedMemberCount: 3,
      );
    await expectLater(
      DirectChatService(backend).openOrCreateDirectChat('@alice:example.test'),
      throwsStateError,
    );
  });
}
