import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/coordinated_direct_chat.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_controller.dart';
import 'package:liuhetong_mobile/features/matrix/direct_room_coordination_storage.dart';

class _Intents implements DirectRoomIntentStore {
  DirectRoomIntent saved = const DirectRoomIntent(attemptId: 'intent');
  @override
  Future<DirectRoomIntent> loadOrCreate(String peer) async => saved;
  @override
  Future<void> saveRoom(
      String peer, DirectRoomIntent intent, String roomId) async {
    saved = DirectRoomIntent(attemptId: intent.attemptId, roomId: roomId);
  }
}

class _Directory implements DirectRoomCoordinator {
  String? canonical;
  bool loseClaim = false, losePublication = false;
  final claims = <String>[], publications = <String>[];
  @override
  Future<String?> canonicalRoomId(String peer) async => canonical;
  @override
  Future<DirectRoomClaim> claim(String peer, String attemptId) async {
    claims.add(attemptId);
    if (loseClaim) {
      loseClaim = false;
      throw const SocketException('claim response lost after reservation');
    }
    return DirectRoomClaim(
        roomId: canonical,
        mayCreate: canonical == null,
        canPublish: canonical == null,
        roomAliasLocalpart: 'chatflow_dm_0123456789abcdef0123456789abcdef',
        reservationId: 'fixed_reservation');
  }

  @override
  Future<String> publish(String peer, String attemptId, String roomId) async {
    publications.add(roomId);
    canonical ??= roomId;
    if (losePublication) {
      losePublication = false;
      throw const SocketException('publication response lost after commit');
    }
    return canonical!;
  }
}

/// Simulates the createReserved callback contract (resolve fixed alias before
/// create). Real Synapse alias collision semantics have a separate server gate.
class _ReservedTransport {
  final aliases = <String, String>{};
  final requests = <String>[];
  int physicalCreates = 0;
  bool loseCreate = false;
  Future<String> call(String peer, String alias, String reservation) async {
    requests.add('$alias/$reservation');
    final room = aliases.putIfAbsent(alias, () {
      physicalCreates++;
      return '!reserved:test';
    });
    if (loseCreate) {
      loseCreate = false;
      throw const SocketException('create response lost after alias commit');
    }
    return room;
  }
}

class _Memory extends Fake implements SecureKeyValueStore {
  @override
  Future<String?> read(String key) async => null;
}

void main() {
  late _Directory directory;
  late _Intents intents;
  late _ReservedTransport transport;
  late CoordinatedDirectChatGateway gateway;
  final opened = <String>[];
  setUp(() {
    directory = _Directory();
    intents = _Intents();
    transport = _ReservedTransport();
    opened.clear();
    gateway = CoordinatedDirectChatGateway(
        coordinator: directory,
        intents: intents,
        businessUserIdOf: (_) => 'peer-business',
        createReserved: transport.call,
        createOnce: (_) async =>
            throw StateError('V2 must never fall back to unaliased creation'),
        findExisting: (_) async => null,
        openExisting: (roomId, peer) async {
          opened.add(roomId);
          return DirectChatRoom(
              roomId: roomId,
              encrypted: true,
              joinedMemberCount: 2,
              participantIds: {'@me:test', peer});
        });
  });
  test(
      'lost claim response reuses durable intent and never invokes legacy create',
      () async {
    directory.loseClaim = true;
    await expectLater(gateway.openOrCreateDirectChat('@peer:test'),
        throwsA(isA<SocketException>()));
    expect(transport.physicalCreates, 0);
    expect((await gateway.openOrCreateDirectChat('@peer:test')).roomId,
        '!reserved:test');
    expect(directory.claims, ['intent', 'intent']);
    expect(transport.requests,
        ['chatflow_dm_0123456789abcdef0123456789abcdef/fixed_reservation']);
  });
  test('lost create response retries the same alias without an unaliased room',
      () async {
    transport.loseCreate = true;
    await expectLater(gateway.openOrCreateDirectChat('@peer:test'),
        throwsA(isA<SocketException>()));
    expect(opened, isEmpty);
    expect((await gateway.openOrCreateDirectChat('@peer:test')).roomId,
        '!reserved:test');
    expect(transport.requests, [
      'chatflow_dm_0123456789abcdef0123456789abcdef/fixed_reservation',
      'chatflow_dm_0123456789abcdef0123456789abcdef/fixed_reservation'
    ]);
    expect(transport.physicalCreates, 1);
    expect(directory.publications, ['!reserved:test']);
  });
  test('lost recovery response reads canonical on retry and does not recreate',
      () async {
    directory.losePublication = true;
    await expectLater(gateway.openOrCreateDirectChat('@peer:test'),
        throwsA(isA<SocketException>()));
    expect(opened, isEmpty);
    expect(intents.saved.roomId, '!reserved:test');
    expect((await gateway.openOrCreateDirectChat('@peer:test')).roomId,
        '!reserved:test');
    expect(transport.physicalCreates, 1);
    expect(directory.publications, ['!reserved:test']);
    expect(opened, ['!reserved:test']);
  });
  test('production coordinator uses claim-v2 and recover contracts', () async {
    final calls = <String>[];
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://test/api/v1/'),
        sessionStore: SecureSessionStore(_Memory()),
        client: MockClient((request) async {
          calls.add(request.url.path.split('/').last);
          expect(request.method, 'POST');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['peer_user_id'], 'peer');
          expect(body['attempt_id'], 'attempt');
          return http.Response(
              jsonEncode(request.url.path.endsWith('/claim-v2')
                  ? {
                      'matrix_room_id': null,
                      'may_create': true,
                      'can_publish': true,
                      'room_alias_localpart':
                          'chatflow_dm_0123456789abcdef0123456789abcdef',
                      'reservation_id': 'fixed_reservation'
                    }
                  : {'matrix_room_id': body['matrix_room_id']}),
              200);
        }));
    final coordinator = ApiDirectRoomCoordinator(api);
    final claim = await coordinator.claim('peer', 'attempt');
    expect(claim.roomAliasLocalpart,
        'chatflow_dm_0123456789abcdef0123456789abcdef');
    expect(claim.reservationId, 'fixed_reservation');
    expect(await coordinator.publish('peer', 'attempt', '!reserved:test'),
        '!reserved:test');
    expect(calls, ['claim-v2', 'recover']);
  });
}
