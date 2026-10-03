import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_recovery_vault.dart';
import 'package:liuhetong_mobile/features/matrix/recent_history_coordinator.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _HistoryClient extends Client {
  _HistoryClient(DatabaseApi database, http.Client transport)
      : super('history-integration',
            databaseBuilder: (_) => database, httpClient: transport);
  @override
  String? get prevBatch => 'login-head';
}

Map<String, dynamic> _event(String id, int timestamp, {bool state = false}) => {
      'event_id': id,
      'type': state ? EventTypes.RoomName : EventTypes.Message,
      'sender': '@synthetic:example.test',
      'origin_server_ts': timestamp,
      if (state) 'state_key': '',
      'content': state
          ? {'name': 'old state'}
          : {'msgtype': MessageTypes.Text, 'body': 'synthetic'},
    };

Future<(_HistoryClient, MatrixSdkDatabase)> _open(
    Future<http.Response> Function(http.Request) handler) async {
  final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  final db = MatrixSdkDatabase('history-integration',
      database: sql, sqfliteFactory: databaseFactoryFfi);
  await db.open();
  final client = _HistoryClient(db, MockClient(handler));
  await client.init();
  client.homeserver = Uri.parse('https://matrix.example.test');
  client.accessToken = 'synthetic';
  return (client, db);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('limited sync bridges a new head after prior complete coverage',
      () async {
    final seen = <String?>[];
    final (client, db) = await _open((request) async {
      if (request.url.path.endsWith('timestamp_to_event')) {
        return http.Response('{"errcode":"M_UNRECOGNIZED"}', 404);
      }
      final token = request.url.queryParameters['from'];
      seen.add(token);
      return http.Response(
          jsonEncode({
            'start': token,
            'chunk': [_event('\$event-$token', 1)]
          }),
          200);
    });
    final room = Room(
        id: '!synthetic:example.test',
        client: client,
        membership: Membership.join);
    client.rooms.add(room);
    final first = Completer<void>(), second = Completer<void>();
    var committed = 0;
    final coordinator = RecentHistoryCoordinator(
        client: client,
        owner: RecoveryOperationOwner(identity: client, isCurrent: () => true),
        databaseGeneration: 'generation',
        status: VaultSyncStatus(),
        onChanged: () {
          if (++committed == 1) {
            first.complete();
          } else if (!second.isCompleted) {
            second.complete();
          }
        });
    try {
      coordinator.start();
      await first.future;
      client.onSync.add(SyncUpdate.fromJson({
        'next_batch': 'gap-head',
        'rooms': {
          'join': {
            room.id: {
              'timeline': {
                'limited': true,
                'events': [],
                'prev_batch': 'live-gap'
              }
            }
          }
        }
      }));
      await second.future.timeout(const Duration(seconds: 3));
      expect(seen, ['login-head', 'gap-head']);
      expect(await db.getEventById(r'$event-gap-head', room), isNotNull);
      expect(client.prevBatch, 'login-head');
    } finally {
      coordinator.revoke();
      await client.dispose();
    }
  });
  test('many rooms keep two network/body pages and bounded SQL replay pages',
      () async {
    var active = 0, maxActive = 0, requests = 0;
    final (client, db) = await _open((request) async {
      if (request.url.path.endsWith('timestamp_to_event')) {
        return http.Response('{"errcode":"M_UNRECOGNIZED"}', 404);
      }
      active++;
      if (active > maxActive) maxActive = active;
      requests++;
      await Future<void>.delayed(Duration.zero);
      final token = request.url.queryParameters['from'];
      final offset = token == 'login-head' ? 0 : int.parse(token!);
      final count = offset < 160 ? 80 : 1;
      active--;
      return http.Response(
          jsonEncode({
            'start': token,
            if (offset < 160) 'end': '${offset + 80}',
            'chunk': [
              for (var i = 0; i < count; i++)
                _event('\$event-${offset + i}', 100000000)
            ]
          }),
          200);
    });
    for (var i = 0; i < 12; i++) {
      client.rooms.add(Room(
          id: '!room-$i:example.test',
          client: client,
          membership: Membership.join));
    }
    final coordinator = RecentHistoryCoordinator(
        client: client,
        owner: RecoveryOperationOwner(identity: client, isCurrent: () => true),
        databaseGeneration: 'generation',
        status: VaultSyncStatus(),
        now: DateTime.fromMillisecondsSinceEpoch(100000000));
    try {
      await coordinator.runOnce();
      expect(requests, 36);
      expect(maxActive, lessThanOrEqualTo(2));
      expect(coordinator.maxRetainedEventBodies, lessThanOrEqualTo(160));
      expect(coordinator.retainedEventBodies, 0);
      for (final room in client.rooms) {
        expect((await db.getRecoveryEventIds(room, limit: 80)).length, 80);
        expect(
            (await db.getRecoveryEventIds(room, start: 160, limit: 80)).length,
            1);
      }
    } finally {
      coordinator.revoke();
      await client.dispose();
    }
  });
  test('real raw pages preserve terminal/state/empty progress and live state',
      () async {
    var requests = 0;
    final (client, db) = await _open((request) async {
      if (request.url.path.endsWith('timestamp_to_event')) {
        return http.Response('{"errcode":"M_UNRECOGNIZED"}', 404);
      }
      requests++;
      final from = request.url.queryParameters['from'];
      final page = switch (from) {
        'login-head' => {
            'chunk': [_event(r'$old-out-of-order', 1)],
            'end': 'empty'
          },
        'empty' => {'chunk': [], 'end': 'terminal'},
        _ => {
            'chunk': [
              _event(r'$terminal', 99999999),
              _event(r'$state', 1, state: true)
            ]
          },
      };
      return http.Response(jsonEncode({'start': from, ...page}), 200);
    });
    final room = Room(
        id: '!synthetic:example.test',
        client: client,
        membership: Membership.join,
        notificationCount: 7,
        highlightCount: 2)
      ..prev_batch = 'foreground';
    client.rooms.add(room);
    final owner =
        RecoveryOperationOwner(identity: client, isCurrent: () => true);
    final coordinator = RecentHistoryCoordinator(
        client: client,
        owner: owner,
        databaseGeneration: 'generation',
        status: VaultSyncStatus(),
        now: DateTime.fromMillisecondsSinceEpoch(100000000));
    try {
      await coordinator.runOnce();
      expect(requests, 3,
          reason: 'old timestamps cannot prove complete contiguous coverage');
      expect(
          (await db.getEventById(r'$terminal', room))?.eventId, r'$terminal');
      expect(
          (await db.getEventById(r'$state', room))?.type, EventTypes.RoomName);
      expect(room.getState(EventTypes.RoomName), isNull);
      expect([
        room.prev_batch,
        room.notificationCount,
        room.highlightCount,
        client.prevBatch
      ], [
        'foreground',
        7,
        2,
        'login-head'
      ]);
      await coordinator.runOnce();
      expect(requests, 3);
    } finally {
      coordinator.revoke();
      await client.dispose();
    }
  });

  test('cyclic cursor commits received rows but remains incomplete', () async {
    var requests = 0;
    final (client, db) = await _open((request) async {
      if (request.url.path.endsWith('timestamp_to_event')) {
        return http.Response('{"errcode":"M_UNRECOGNIZED"}', 404);
      }
      requests++;
      final token = request.url.queryParameters['from'];
      return http.Response(
          jsonEncode({
            'start': token,
            'end': token == 'cycle-a' ? 'cycle-b' : 'cycle-a',
            'chunk': [_event('\$event-$requests', 1)]
          }),
          200);
    });
    final room = Room(
        id: '!synthetic:example.test',
        client: client,
        membership: Membership.join);
    client.rooms.add(room);
    final coordinator = RecentHistoryCoordinator(
        client: client,
        owner: RecoveryOperationOwner(identity: client, isCurrent: () => true),
        databaseGeneration: 'generation',
        status: VaultSyncStatus());
    try {
      await expectLater(coordinator.runOnce(), throwsA(isA<VaultFailure>()));
      expect(requests, 3);
      expect(await db.getEventById(r'$event-3', room), isNotNull);
    } finally {
      coordinator.revoke();
      await client.dispose();
    }
  });

  test('late raw page after revoke never starts a database ingest', () async {
    final entered = Completer<void>(), response = Completer<http.Response>();
    final (client, db) = await _open((request) async {
      if (request.url.path.endsWith('timestamp_to_event')) {
        return http.Response('{"errcode":"M_UNRECOGNIZED"}', 404);
      }
      entered.complete();
      return response.future;
    });
    final room = Room(
        id: '!synthetic:example.test',
        client: client,
        membership: Membership.join);
    client.rooms.add(room);
    final owner =
        RecoveryOperationOwner(identity: client, isCurrent: () => true);
    final coordinator = RecentHistoryCoordinator(
        client: client,
        owner: owner,
        databaseGeneration: 'generation',
        status: VaultSyncStatus());
    final run = coordinator.runOnce();
    await entered.future;
    owner.revoke();
    coordinator.revoke();
    final failed = expectLater(run, throwsStateError);
    response.complete(http.Response(
        jsonEncode({
          'start': 'login-head',
          'chunk': [_event(r'$late', 1)]
        }),
        200));
    await failed;
    expect(await db.getEventById(r'$late', room), isNull);
    expect(owner.pendingWrites, 0);
    await client.dispose();
  });
}
