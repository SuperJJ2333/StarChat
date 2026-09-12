import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_controller.dart';
import 'package:liuhetong_mobile/features/matrix/coordinated_direct_chat.dart';

DirectChatRoom room(String id, String peer) => DirectChatRoom(
      roomId: id,
      encrypted: true,
      joinedMemberCount: 2,
      participantIds: {'@a:test', '@b:test'},
    );

class Store implements DirectRoomIntentStore {
  Store(this.attempt);
  final String attempt;
  DirectRoomIntent? saved;
  @override
  Future<DirectRoomIntent> loadOrCreate(String peer) async =>
      saved ??= DirectRoomIntent(attemptId: attempt);
  @override
  Future<void> saveRoom(
      String peer, DirectRoomIntent intent, String roomId) async {
    saved = DirectRoomIntent(attemptId: intent.attemptId, roomId: roomId);
  }
}

// Models the server's atomic pair decision; backend contention is tested
// separately against real database transactions, not inferred from this fake.
class Directory implements DirectRoomCoordinator {
  var canonicalCalls = 0;
  String? owner;
  String? canonical;
  bool failLookup = false;
  bool failPublish = false;
  @override
  Future<String?> canonicalRoomId(String peer) async {
    canonicalCalls++;
    if (failLookup) throw StateError('directory unavailable');
    return canonical;
  }

  @override
  Future<DirectRoomClaim> claim(String peer, String attempt) async {
    if (canonical != null) return DirectRoomClaim(roomId: canonical);
    final first = owner == null;
    owner ??= attempt;
    return DirectRoomClaim(mayCreate: first, canPublish: owner == attempt);
  }

  @override
  Future<String> publish(String peer, String attempt, String roomId) async {
    if (failPublish) throw StateError('publish unavailable');
    if (owner != attempt) throw StateError('wrong owner');
    return canonical ??= roomId;
  }
}

void main() {
  for (final resumed in [false, true]) {
    test('repairs an unregistered single-member room, resumed=$resumed',
        () async {
      final directory = Directory()..owner = resumed ? 'a' : null;
      var creates = 0;
      var repairs = 0;
      var failRepair = true;
      final gateway = CoordinatedDirectChatGateway(
        coordinator: directory,
        intents: Store('a'),
        businessUserIdOf: (_) => 'peer',
        createOnce: (peer) async {
          creates++;
          return room('!duplicate:test', peer);
        },
        findExisting: (_) async => DirectChatRoom(
          roomId: '!legacy:test',
          encrypted: true,
          joinedMemberCount: 1,
          participantIds: {'@a:test'},
        ),
        openExisting: (id, peer) async {
          repairs++;
          expect(id, '!legacy:test');
          expect(peer, '@b:test');
          if (failRepair) throw StateError('invite pending');
          return room(id, peer);
        },
      );
      await expectLater(
          gateway.openOrCreateDirectChat('@b:test'), throwsStateError);
      expect(repairs, 1);
      expect(directory.canonical, isNull);
      failRepair = false;
      expect((await gateway.openOrCreateDirectChat('@b:test')).roomId,
          '!legacy:test');
      expect(directory.canonical, '!legacy:test');
      expect(creates, 0);
      expect(repairs, 2);
    });
  }

  CoordinatedDirectChatGateway gateway(Directory directory, Store store,
          Future<DirectChatRoom> Function(String) create,
          {Future<DirectChatRoom?> Function(String)? recover,
          Future<DirectChatRoom> Function(String, String)? open,
          String? businessId = 'peer'}) =>
      CoordinatedDirectChatGateway(
        coordinator: directory,
        intents: store,
        businessUserIdOf: (_) => businessId,
        createOnce: create,
        findExisting: recover ?? (_) async => null,
        openExisting: open ?? (id, peer) async => room(id, peer),
        wait: (_) async => Future<void>.delayed(Duration.zero),
        waitAttempts: 5,
      );

  test('opposite clients create once before publishing, both use one room',
      () async {
    final directory = Directory();
    var creates = 0;
    Future<DirectChatRoom> create(String peer) async {
      creates++;
      await Future<void>.delayed(Duration.zero);
      return room('!one:test', peer);
    }

    final a = gateway(directory, Store('a'), create);
    final b = gateway(directory, Store('b'), create);
    final results = await Future.wait([
      a.openOrCreateDirectChat('@b:test'),
      b.openOrCreateDirectChat('@a:test'),
    ]);
    expect(creates, 1);
    expect(results.map((r) => r.roomId), everyElement('!one:test'));
  });

  test('lookup failure and missing identity never authorize a create',
      () async {
    final directory = Directory()..failLookup = true;
    var creates = 0;
    Future<DirectChatRoom> create(String peer) async {
      creates++;
      return room('!wrong:test', peer);
    }

    await expectLater(
        gateway(directory, Store('a'), create)
            .openOrCreateDirectChat('@b:test'),
        throwsStateError);
    await expectLater(
        gateway(Directory(), Store('a'), create, businessId: null)
            .openOrCreateDirectChat('@b:test'),
        throwsStateError);
    expect(creates, 0);
    expect(directory.owner, isNull);
  });

  test('safe local snapshot opens without canonical coordination', () async {
    final directory = Directory();
    final gateway = CoordinatedDirectChatGateway(
      coordinator: directory,
      intents: Store('a'),
      businessUserIdOf: (_) => 'peer',
      createOnce: (_) async => throw StateError('must not create'),
      findExisting: (_) async => throw StateError('must not recover'),
      findCached: (_) async => room('!cached:test', '@b:test'),
      openExisting: (_, __) async => throw StateError('must not repair'),
    );
    expect((await gateway.openOrCreateDirectChat('@b:test')).roomId,
        '!cached:test');
    expect(directory.canonicalCalls, 0);
  });

  test('an inconclusive local snapshot retains the canonical failure path',
      () async {
    final directory = Directory()..failLookup = true;
    var creates = 0;
    final gateway = CoordinatedDirectChatGateway(
      coordinator: directory,
      intents: Store('a'),
      businessUserIdOf: (_) => 'peer',
      createOnce: (_) async {
        creates++;
        return room('!unexpected:test', '@b:test');
      },
      findExisting: (_) async => null,
      findCached: (_) async => null,
      openExisting: (_, __) async => throw StateError('must not open'),
    );

    await expectLater(
        gateway.openOrCreateDirectChat('@b:test'), throwsStateError);
    expect(directory.canonicalCalls, 1);
    expect(creates, 0, reason: 'a cache miss/error is not authority to create');
  });

  test('unknown create outcome remains reserved on restart; no second create',
      () async {
    final directory = Directory();
    final store = Store('a');
    var creates = 0;
    Future<DirectChatRoom> create(String peer) async {
      creates++;
      throw TimeoutException('Matrix response lost');
    }

    await expectLater(
        gateway(directory, store, create).openOrCreateDirectChat('@b:test'),
        throwsA(isA<TimeoutException>()));
    await expectLater(
        gateway(directory, store, create).openOrCreateDirectChat('@b:test'),
        throwsA(isA<DirectRoomPendingException>()));
    expect(creates, 1);
  });

  test('publication failure recovers persisted result after restart', () async {
    final directory = Directory()..failPublish = true;
    final store = Store('a');
    var creates = 0;
    Future<DirectChatRoom> create(String peer) async {
      creates++;
      return room('!one:test', peer);
    }

    await expectLater(
        gateway(directory, store, create).openOrCreateDirectChat('@b:test'),
        throwsStateError);
    expect(store.saved?.roomId, '!one:test');
    directory.failPublish = false;
    expect(
        (await gateway(directory, store, create)
                .openOrCreateDirectChat('@b:test'))
            .roomId,
        '!one:test');
    expect(creates, 1);
  });

  test('uncertain creation recovers only existing safe room', () async {
    final directory = Directory()..owner = 'a';
    var creates = 0;
    final result = await gateway(directory, Store('a'), (peer) async {
      creates++;
      return room('!wrong:test', peer);
    }, recover: (peer) async => room('!recovered:test', peer))
        .openOrCreateDirectChat('@b:test');
    expect(result.roomId, '!recovered:test');
    expect(directory.canonical, '!recovered:test');
    expect(creates, 0);
  });

  test('another contender never publishes its local legacy room', () async {
    final directory = Directory()..owner = 'other';
    var finds = 0;
    await expectLater(
        gateway(
            directory, Store('a'), (peer) async => room('!wrong:test', peer),
            recover: (peer) async {
          finds++;
          return room('!legacy:test', peer);
        }).openOrCreateDirectChat('@b:test'),
        throwsA(isA<DirectRoomPendingException>()));
    expect(finds, 0);
    expect(directory.canonical, isNull);
  });

  test('initial owner preserves existing room and never replaces unsafe one',
      () async {
    var creates = 0;
    Future<DirectChatRoom> create(String peer) async {
      creates++;
      return room('!new:test', peer);
    }

    final safe = await gateway(Directory(), Store('a'), create,
            recover: (peer) async => room('!legacy:test', peer))
        .openOrCreateDirectChat('@b:test');
    expect(safe.roomId, '!legacy:test');
    await expectLater(
        gateway(Directory(), Store('b'), create,
                recover: (_) async => const DirectChatRoom(
                    roomId: '!unsafe:test',
                    encrypted: false,
                    joinedMemberCount: 2,
                    participantIds: {'@a:test', '@b:test'}),
                open: (id, peer) async => DirectChatRoom(
                    roomId: id,
                    encrypted: false,
                    joinedMemberCount: 2,
                    participantIds: {'@a:test', '@b:test'}))
            .openOrCreateDirectChat('@b:test'),
        throwsStateError);
    expect(creates, 0);
  });
}
