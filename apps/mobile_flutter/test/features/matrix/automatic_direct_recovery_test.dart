import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/coordinated_direct_chat.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_controller.dart';
import 'package:liuhetong_mobile/features/matrix/direct_room_coordination_storage.dart';

class _Memory extends Fake implements SecureKeyValueStore {
  @override
  Future<String?> read(String key) async => null;
}

class _Intents implements DirectRoomIntentStore {
  final intent = const DirectRoomIntent(
      attemptId: '12345678-1234-4234-8234-123456789abc',
      roomId: '!retired:test');
  @override
  Future<DirectRoomIntent> loadOrCreate(String peer) async => intent;
  @override
  Future<void> saveRoom(
      String peer, DirectRoomIntent intent, String roomId) async {}
}

void main() {
  for (final status in [
    'ready',
    'join_required',
    'create_required',
    'unavailable'
  ]) {
    test(
        'lifecycle $status never opens retired canonical or uses legacy creation',
        () async {
      final calls = <String>[];
      final aliases = <String>[];
      final opened = <String>[];
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://test/api/v1/'),
          sessionStore: SecureSessionStore(_Memory()),
          client: MockClient((request) async {
            calls.add(request.url.path.split('/').last);
            if (request.method == 'GET') {
              return http.Response('{"matrix_room_id":"!retired:test"}', 200);
            }
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['peer_user_id'], 'peer');
            expect(body['attempt_id'], '12345678-1234-4234-8234-123456789abc');
            if (request.url.path.endsWith('/publish-recovery')) {
              expect(body['generation'], 2);
              expect(body['reservation_id'],
                  '12345678-1234-4234-8234-123456789abc');
              expect(body['matrix_room_id'], '!new:test');
              return http.Response(
                  '{"matrix_room_id":"!new:test","generation":2,"revision":3}',
                  200);
            }
            expect(request.url.path.endsWith('/resolve'), isTrue);
            return http.Response(
                jsonEncode({
                  'status': status,
                  'generation': 2,
                  'revision': 2,
                  'matrix_room_id':
                      status == 'ready' || status == 'join_required'
                          ? '!new:test'
                          : null,
                  'room_ids': ['!retired:test'],
                  'room_alias_localpart': status == 'create_required'
                      ? 'chatflow_dm_0123456789abcdef0123456789abcdef'
                      : null,
                  'reservation_id': status == 'create_required'
                      ? '12345678-1234-4234-8234-123456789abc'
                      : null
                }),
                200);
          }));
      final gateway = CoordinatedDirectChatGateway(
          coordinator: ApiDirectRoomCoordinator(api),
          intents: _Intents(),
          businessUserIdOf: (_) => 'peer',
          createOnce: (_) async => throw StateError('unaliased create'),
          findExisting: (_) async => null,
          createReserved: (peer, alias, reservation) async {
            aliases.add(alias);
            return '!new:test';
          },
          openExisting: (room, peer) async {
            opened.add(room);
            return DirectChatRoom(
                roomId: room,
                encrypted: true,
                joinedMemberCount: 2,
                participantIds: {'@me:test', peer});
          });
      if (status == 'unavailable') {
        await expectLater(gateway.openOrCreateDirectChat('@peer:test'),
            throwsA(isA<DirectRoomPendingException>()));
        expect(opened, isEmpty);
      } else {
        expect((await gateway.openOrCreateDirectChat('@peer:test')).roomId,
            '!new:test');
        expect(opened, ['!new:test']);
      }
      expect(aliases.length, status == 'create_required' ? 1 : 0);
      expect(
          calls,
          status == 'create_required'
              ? ['resolve', 'publish-recovery']
              : ['resolve']);
    });
  }
  test('late resolver response cannot roll back a newer primary', () async {
    final first = Completer<http.Response>();
    var count = 0;
    Map<String, Object?> response(int revision) => {
          'status': 'ready',
          'generation': 0,
          'revision': revision,
          'matrix_room_id': '!room$revision:test',
          'room_ids': <String>[]
        };
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://test/api/v1/'),
        sessionStore: SecureSessionStore(_Memory()),
        client: MockClient((_) async {
          if (++count == 1) return first.future;
          return http.Response(jsonEncode(response(2)), 200);
        }));
    final coordinator = ApiDirectRoomCoordinator(api);
    final old = coordinator.resolve('peer', 'attempt');
    while (count == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await coordinator.resolve('peer', 'attempt');
    final rejected = expectLater(old, throwsStateError);
    first.complete(http.Response(jsonEncode(response(1)), 200));
    await rejected;
  });
  test('offers a safe cached source before creating a recovery generation',
      () async {
    final calls = <String>[];
    var offered = false;
    var creates = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://test/api/v1/'),
        sessionStore: SecureSessionStore(_Memory()),
        client: MockClient((request) async {
          final path = request.url.path.split('/').last;
          calls.add(path);
          if (path == 'associations') {
            offered = true;
            return http.Response('{}', 200);
          }
          return http.Response(
              jsonEncode({
                'status': offered ? 'ready' : 'create_required',
                'generation': 1,
                'revision': offered ? 2 : 1,
                'matrix_room_id': offered ? '!cached:test' : null,
                'room_ids': ['!retired:test'],
                'room_alias_localpart':
                    'chatflow_dm_0123456789abcdef0123456789abcdef',
                'reservation_id': '12345678-1234-4234-8234-123456789abc'
              }),
              200);
        }));
    DirectChatRoom room(String id) => DirectChatRoom(
        roomId: id,
        encrypted: true,
        joinedMemberCount: 2,
        participantIds: {'@me:test', '@peer:test'});
    final gateway = CoordinatedDirectChatGateway(
        coordinator: ApiDirectRoomCoordinator(api),
        intents: _Intents(),
        businessUserIdOf: (_) => 'peer',
        createOnce: (_) async => throw StateError('legacy'),
        findExisting: (_) async =>
            throw StateError('must not repair during discovery'),
        findCached: (_) async => room('!cached:test'),
        createReserved: (_, __, ___) async {
          creates++;
          throw StateError('must reuse');
        },
        openExisting: (id, _) async => room(id));
    expect((await gateway.openOrCreateDirectChat('@peer:test')).roomId,
        '!cached:test');
    expect(creates, 0);
    expect(calls, ['resolve', 'associations', 'resolve']);
  });
  test(
      'late legacy directory response cannot authorize old primary after resolve',
      () async {
    final oldResponse = Completer<http.Response>();
    final started = Completer<void>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://test/api/v1/'),
        sessionStore: SecureSessionStore(_Memory()),
        client: MockClient((request) async {
          if (request.method == 'GET') {
            started.complete();
            return oldResponse.future;
          }
          return http.Response(
              jsonEncode({
                'status': 'ready',
                'generation': 0,
                'revision': 2,
                'matrix_room_id': '!new:test',
                'room_ids': ['!old:test']
              }),
              200);
        }));
    final old = api.canonicalDirectRoomId('peer');
    await started.future;
    await ApiDirectRoomCoordinator(api).resolve('peer', 'attempt');
    final rejected = expectLater(old, throwsStateError);
    oldResponse.complete(
        http.Response('{"matrix_room_id":"!old:test","revision":1}', 200));
    await rejected;
  });
  for (final lostStage in ['create', 'publish']) {
    test(
        'generation retry after lost $lostStage response never creates a second room',
        () async {
      var published = false;
      var lose = true;
      final physical = <String, String>{};
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://test/api/v1/'),
          sessionStore: SecureSessionStore(_Memory()),
          client: MockClient((request) async {
            if (request.url.path.endsWith('/publish-recovery')) {
              published = true;
              if (lostStage == 'publish' && lose) {
                lose = false;
                throw const SocketException('lost publication');
              }
              return http.Response(
                  '{"matrix_room_id":"!new:test","generation":2,"revision":3}',
                  200);
            }
            return http.Response(
                jsonEncode({
                  'status': published ? 'ready' : 'create_required',
                  'generation': 2,
                  'revision': published ? 3 : 2,
                  'matrix_room_id': published ? '!new:test' : null,
                  'room_ids': ['!old:test'],
                  'room_alias_localpart':
                      'chatflow_dm_0123456789abcdef0123456789abcdef',
                  'reservation_id': '12345678-1234-4234-8234-123456789abc'
                }),
                200);
          }));
      final gateway = CoordinatedDirectChatGateway(
          coordinator: ApiDirectRoomCoordinator(api),
          intents: _Intents(),
          businessUserIdOf: (_) => 'peer',
          createOnce: (_) async => throw StateError('legacy'),
          findExisting: (_) async => null,
          createReserved: (_, alias, __) async {
            final id = physical.putIfAbsent(alias, () => '!new:test');
            if (lostStage == 'create' && lose) {
              lose = false;
              throw const SocketException('lost create');
            }
            return id;
          },
          openExisting: (id, peer) async => DirectChatRoom(
              roomId: id,
              encrypted: true,
              joinedMemberCount: 2,
              participantIds: {'@me:test', peer}));
      await expectLater(gateway.openOrCreateDirectChat('@peer:test'),
          throwsA(isA<SocketException>()));
      expect((await gateway.openOrCreateDirectChat('@peer:test')).roomId,
          '!new:test');
      expect(physical.length, 1);
    });
  }
  test('owner change while resolving prevents opening or creating rooms',
      () async {
    final response = Completer<http.Response>();
    final started = Completer<void>();
    var token = 1;
    var opened = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://test/api/v1/'),
        sessionStore: SecureSessionStore(_Memory()),
        client: MockClient((_) async {
          started.complete();
          return response.future;
        }));
    final gateway = CoordinatedDirectChatGateway(
        coordinator: ApiDirectRoomCoordinator(api),
        intents: _Intents(),
        ownerToken: () => token,
        businessUserIdOf: (_) => 'peer',
        createOnce: (_) async => throw StateError('legacy'),
        findExisting: (_) async => null,
        openExisting: (id, peer) async {
          opened++;
          throw StateError('stale');
        });
    final opening = gateway.openOrCreateDirectChat('@peer:test');
    await started.future;
    token++;
    final rejected = expectLater(opening, throwsStateError);
    response.complete(http.Response(
        '{"status":"ready","generation":0,"revision":2,"matrix_room_id":"!new:test","room_ids":[]}',
        200));
    await rejected;
    expect(opened, 0);
  });
}
