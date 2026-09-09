import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_controller.dart';

const _peer = '@peer:example.test';
const _canonicalId = '!canonical:example.test';

DirectChatRoom _room(String id, {bool encrypted = true, String peer = _peer}) =>
    DirectChatRoom(
      roomId: id,
      encrypted: encrypted,
      joinedMemberCount: 2,
      participantIds: {'@self:example.test', peer},
    );

void main() {
  test('canonical sync timeout cannot create a duplicate while local rooms lag',
      () async {
    final backend = _LaggingBackend();
    final directory = _Directory();
    final timeout = TimeoutException('Canonical room has not reached sync');
    var synced = false;
    final opened = <String>[];
    final controller = DirectChatController(CanonicalDirectChatGateway(
      inner: DirectChatService(backend),
      directory: directory,
      businessUserIdOf: (_) => 'peer-business-id',
      openExistingRoom: (id) async {
        opened.add(id);
        if (!synced) throw timeout;
        return _room(id);
      },
    ));
    addTearDown(controller.dispose);

    Object? failure;
    DirectChatRoom? unexpectedRoom;
    try {
      unexpectedRoom = await controller.open(_peer);
    } catch (error) {
      failure = error;
    }

    expect(backend.creates, 0,
        reason: 'A known canonical room timing out is not proof it is gone; '
            'absent local sync must not trigger creation');
    expect(directory.registrations, isEmpty);
    expect(unexpectedRoom, isNull);
    expect(failure, same(timeout));
    expect(controller.state, DirectChatState.failed);

    synced = true;
    final room = await controller.retry();
    expect(room.roomId, _canonicalId);
    expect(opened, [_canonicalId, _canonicalId]);
    expect(backend.creates, 0);
    expect(directory.registrations, isEmpty);
    expect(controller.state, DirectChatState.ready);
  });

  test('registration conflict canonical sync timeout cannot return replacement',
      () async {
    final backend = _LaggingBackend();
    final directory = _Directory(canonical: null);
    final timeout = TimeoutException('Conflicting canonical room sync delayed');
    final opened = <String>[];
    final controller = DirectChatController(CanonicalDirectChatGateway(
      inner: DirectChatService(backend),
      directory: directory,
      businessUserIdOf: (_) => 'peer-business-id',
      openExistingRoom: (id) async {
        opened.add(id);
        throw timeout;
      },
    ));
    addTearDown(controller.dispose);

    Object? failure;
    DirectChatRoom? unexpectedRoom;
    try {
      unexpectedRoom = await controller.open(_peer);
    } catch (error) {
      failure = error;
    }

    expect(backend.creates, 1,
        reason: 'Initial directory lookup has no canonical room');
    expect(directory.registrations, ['!replacement:example.test']);
    expect(opened, [_canonicalId]);
    expect(failure, same(timeout),
        reason: 'After the directory selects a conflicting canonical room, '
            'its sync timeout must propagate instead of accepting replacement');
    expect(unexpectedRoom, isNull);
    expect(controller.state, DirectChatState.failed);
  });

  for (final unsafe in [
    _room(_canonicalId, peer: '@wrong-peer:example.test'),
    _room(_canonicalId, encrypted: false),
  ]) {
    test(
        'unsafe canonical room fails closed without replacement '
        '(encrypted=${unsafe.encrypted}, participants=${unsafe.participantIds})',
        () async {
      final backend = _LaggingBackend()..existing = unsafe;
      final directory = _Directory();
      final gateway = CanonicalDirectChatGateway(
        inner: DirectChatService(backend),
        directory: directory,
        businessUserIdOf: (_) => 'peer-business-id',
        openExistingRoom: (_) async => unsafe,
      );

      await expectLater(
          gateway.openOrCreateDirectChat(_peer), throwsStateError);
      expect(backend.repairs, 0);
      expect(backend.creates, 0);
      expect(backend.avoidedRoomId, isNull);
    });
  }
}

final class _Directory implements CanonicalDirectRoomDirectory {
  _Directory({this.canonical = _canonicalId});

  final String? canonical;
  final registrations = <String>[];

  @override
  Future<String?> canonicalRoomId(String peerUserId) async => canonical;

  @override
  Future<String?> registerRoom(String peerUserId, String roomId) async {
    registrations.add(roomId);
    // Model the server keeping the existing canonical mapping on conflict.
    return _canonicalId;
  }
}

final class _LaggingBackend implements DirectChatBackend {
  DirectChatRoom? existing;
  int creates = 0;
  int repairs = 0;
  String? avoidedRoomId;

  @override
  Future<DirectChatRoom?> findJoinedDirectRoom(String matrixUserId) async =>
      existing;

  @override
  Future<String> createEncryptedDirectRoom(String matrixUserId,
      {String? avoidRoomId}) async {
    creates++;
    avoidedRoomId = avoidRoomId;
    return '!replacement:example.test';
  }

  @override
  Future<DirectChatRoom?> repairDirectRoom(
      DirectChatRoom room, String matrixUserId) async {
    repairs++;
    return null;
  }

  @override
  Future<DirectChatRoom> waitForRoom(String roomId) async => _room(roomId);
}
