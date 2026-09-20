import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/direct_room_directory_convergence.dart';
import 'package:liuhetong_mobile/features/matrix/duplicate_room_registry.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'logical_conversation_reliability_test.dart' show AssociationClient;
import 'direct_room_identity_integration_test.dart' show IdentityFlowRoom;

AssociationClient fixture() {
  final client = AssociationClient();
  for (final id in ['!old:test', '!primary:test']) {
    client.roomsById[id] =
        IdentityFlowRoom(client: client, id: id, membership: Membership.join);
  }
  client.directory['@peer:test'] = ['!old:test', '!primary:test'];
  return client;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('acknowledged associations are not republished on each sync', () async {
    final client = fixture();
    final registry = DuplicateRoomRegistry();
    final acknowledged = <String>{'!primary:test'};
    final writes = <List<String>>[];
    Future<void> converge() => convergeDirectDirectory(client,
        registry: registry,
        businessUserIdOf: (_) => 'peer-business',
        associationsOf: (_) async => DirectRoomAssociations(
            primaryRoomId: '!primary:test', roomIds: acknowledged.toList()),
        publishAssociations: (_, rooms) async {
          writes.add(rooms);
          acknowledged.addAll(rooms);
        });
    await converge();
    expect(writes, [
      ['!old:test']
    ]);
    for (var i = 0; i < 20; i++) {
      await converge();
    }
    expect(
        writes,
        [
          ['!old:test']
        ],
        reason:
            'unchanged background sync must not consume send recovery quota');
  });

  test('failed missing association remains retryable until acknowledged',
      () async {
    final client = fixture();
    final registry = DuplicateRoomRegistry();
    final writes = <List<String>>[];
    for (var i = 0; i < 2; i++) {
      await convergeDirectDirectory(client,
          registry: registry,
          businessUserIdOf: (_) => 'peer-business',
          associationsOf: (_) async => const DirectRoomAssociations(
              primaryRoomId: '!primary:test', roomIds: ['!primary:test']),
          publishAssociations: (_, rooms) async {
            writes.add(rooms);
            throw StateError('temporary failure');
          });
    }
    expect(writes, [
      ['!old:test'],
      ['!old:test']
    ]);
  });

  test('slow peer does not block other peer identity recovery', () async {
    final client = AssociationClient();
    final registry = DuplicateRoomRegistry();
    final held = Completer<DirectRoomAssociations?>();
    final queried = <String>[];
    final done = convergeDirectDirectory(client,
        registry: registry,
        knownMatrixPeers: ['@slow:test', '@fast:test'],
        businessUserIdOf: (id) => id,
        associationsOf: (peer) async {
          queried.add(peer);
          if (peer == '@slow:test') return held.future;
          return const DirectRoomAssociations(
              primaryRoomId: '!fast:test', roomIds: ['!fast:test']);
        });
    try {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(queried, contains('@fast:test'));
      expect(registry.primaryRoomIdForPeer('@me:test', '@fast:test'),
          '!fast:test');
    } finally {
      held.complete(null);
      await done;
    }
  });

  test('canonical unavailable leaves original cross-device directory untouched',
      () async {
    final client = fixture();
    await convergeDirectDirectory(client,
        businessUserIdOf: (_) => 'peer',
        canonicalRoomIdOf: (_) async => throw StateError('offline'));
    expect(client.directory['@peer:test'], ['!old:test', '!primary:test']);
    expect(client.accountWrites, isEmpty);
  });
  test(
      'canonical stores per-source account metadata without rewriting m.direct',
      () async {
    final client = fixture();
    final registry = DuplicateRoomRegistry();
    await convergeDirectDirectory(client,
        registry: registry,
        businessUserIdOf: (_) => 'peer',
        canonicalRoomIdOf: (_) async => '!primary:test');
    expect(client.directory['@peer:test'], ['!old:test', '!primary:test']);
    expect(client.accountWrites.length, 2);
    expect(registry.primaryRoomIdForDuplicate('@me:test', '!old:test'),
        '!primary:test');
    expect(client.roomsById['!old:test']!.membership, Membership.join);
    await convergeDirectDirectory(client,
        registry: registry,
        businessUserIdOf: (_) => 'peer',
        canonicalRoomIdOf: (_) async => '!primary:test');
    expect(client.accountWrites.length, 2,
        reason: 'unchanged metadata is not written again');
  });
  test(
      'server associations restore previously collapsed unseen historical rooms on new device',
      () async {
    final client = fixture();
    client.directory['@peer:test'] = ['!primary:test'];
    final registry = DuplicateRoomRegistry();
    final lookups = <String>[];
    await convergeDirectDirectory(client,
        registry: registry,
        businessUserIdOf: (_) => 'peer-business',
        associationsOf: (peer) async {
          lookups.add(peer);
          return const DirectRoomAssociations(
              primaryRoomId: '!primary:test',
              roomIds: ['!primary:test', '!not-synced:test']);
        });
    expect(lookups, ['peer-business']);
    expect(registry.primaryRoomIdForDuplicate('@me:test', '!not-synced:test'),
        '!primary:test');
    expect(client.getRoomById('!not-synced:test'), isNull);
    expect(
        client.accountWrites
            .any((body) => body['room_id'] == '!not-synced:test'),
        isTrue);
    final secondDevice = AssociationClient();
    secondDevice.accountData.addAll(client.accountData);
    final recovered = DuplicateRoomRegistry();
    await loadDirectRoomAssociations(secondDevice, recovered);
    expect(recovered.primaryRoomIdForDuplicate('@me:test', '!not-synced:test'),
        '!primary:test');
  });
  test(
      'publishes local verified rooms using business identity and preserves local data on network failure',
      () async {
    final client = fixture();
    final published = <String>[];
    await convergeDirectDirectory(client,
        registry: DuplicateRoomRegistry(),
        businessUserIdOf: (_) => 'peer-business',
        canonicalRoomIdOf: (_) async => '!primary:test',
        publishAssociations: (peer, rooms) async {
          expect(peer, 'peer-business');
          published.addAll(rooms);
          throw StateError('offline');
        });
    expect(published.toSet(), {'!old:test', '!primary:test'});
    expect(client.directory['@peer:test'], ['!old:test', '!primary:test']);
    expect(client.accountWrites.length, 2);
  });
  test(
      'account metadata of a peer absent from m.direct still reaches server recovery',
      () async {
    final client = AssociationClient();
    final type =
        '$directConversationAssociationPrefix${Uri.encodeComponent('!historical:test')}';
    client.accountData[type] = BasicEvent(type: type, content: {
      'room_id': '!historical:test',
      'peer_id': '@peer:test',
      'primary_room_id': '!primary:test'
    });
    final registry = DuplicateRoomRegistry();
    var queried = false;
    await convergeDirectDirectory(client,
        registry: registry,
        businessUserIdOf: (_) => 'peer',
        associationsOf: (_) async {
          queried = true;
          return const DirectRoomAssociations(
              primaryRoomId: '!primary:test',
              roomIds: ['!historical:test', '!primary:test']);
        });
    expect(queried, isTrue);
    expect(registry.primaryRoomIdForPeer('@me:test', '@peer:test'),
        '!primary:test');
  });
  test('missing business identity never queries or mutates authority',
      () async {
    final client = fixture();
    await convergeDirectDirectory(client,
        businessUserIdOf: (_) => null,
        canonicalRoomIdOf: (_) async => throw StateError('must not query'));
    expect(client.accountWrites, isEmpty);
    expect(client.directory['@peer:test'], ['!old:test', '!primary:test']);
  });
}
