import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
      'independent terminal page stores events and CAS without live room changes',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final database = MatrixSdkDatabase('recovery-history',
        database: sql, sqfliteFactory: databaseFactoryFfi);
    await database.open();
    final client = Client('recovery-history', databaseBuilder: (_) => database);
    await client.init();
    final room = Room(id: '!synthetic:example.test', client: client)
      ..prev_batch = 'live';
    client.rooms.add(room);
    final events = [
      {
        'event_id': r'$terminal',
        'sender': '@synthetic:example.test',
        'origin_server_ts': 1,
        'type': EventTypes.Message,
        'content': {'msgtype': MessageTypes.Text, 'body': 'synthetic'}
      }
    ];
    try {
      final dynamic api = database;
      final result = await api.commitRecoveryHistoryPage(room, 'owner-window',
          0, events, {'revision': 1, 'cursor': null, 'complete': true});
      expect(result, isTrue);
      expect(
          (await database.getEventById(r'$terminal', room))?.body, 'synthetic');
      expect(room.prev_batch, 'live');
      expect(client.prevBatch, isNull);
      expect(
          await api.commitRecoveryHistoryPage(room, 'owner-window', 0, events,
              {'revision': 1, 'cursor': 'stale', 'complete': false}),
          isFalse);
      expect((await api.getRecoveryCheckpoint('owner-window'))['complete'],
          isTrue);
      await database.commitRecoveryHistoryPage(room, 'redactions', 0, [
        {
          'event_id': r'$redaction',
          'type': EventTypes.Redaction,
          'sender': '@synthetic:example.test',
          'origin_server_ts': 2,
          'redacts': r'$late-target',
          'content': <String, dynamic>{},
        }
      ], {
        'revision': 1
      });
      await database.commitRecoveryHistoryPage(room, 'redactions', 1, [
        {
          ...events.single,
          'event_id': r'$late-target',
        }
      ], {
        'revision': 2
      });
      expect((await database.getEventById(r'$late-target', room))!.redacted,
          isTrue,
          reason:
              'backward pagination receives the redaction before its target');
      await database.commitRecoveryHistoryPage(room, 'same-page', 0, [
        {
          'event_id': r'$redaction-2',
          'type': EventTypes.Redaction,
          'sender': '@synthetic:example.test',
          'origin_server_ts': 2,
          'redacts': r'$same-page-target',
          'content': <String, dynamic>{},
        },
        {...events.single, 'event_id': r'$same-page-target'}
      ], {
        'revision': 1
      });
      expect(
          (await database.getEventById(r'$same-page-target', room))!.redacted,
          isTrue);
    } finally {
      await client.dispose();
    }
  });
  test('local session export reads bounded actual cursor pages', () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final database = MatrixSdkDatabase('recovery-page',
        database: sql, sqfliteFactory: databaseFactoryFfi);
    await database.open();
    try {
      for (var i = 0; i < 161; i++) {
        await database.storeInboundGroupSession(
            '!synthetic:example.test',
            'session-${i.toString().padLeft(3, '0')}',
            'synthetic-pickle',
            '{}',
            '{}',
            '{}',
            'sender',
            '{}');
      }
      final dynamic api = database;
      final first = await api.getInboundGroupSessionsPage(limit: 80);
      final second = await api.getInboundGroupSessionsPage(
          afterSessionId: first.last.sessionId, limit: 80);
      final third = await api.getInboundGroupSessionsPage(
          afterSessionId: second.last.sessionId, limit: 80);
      expect([first.length, second.length, third.length], [80, 80, 1]);
      expect(first.first.sessionId, 'session-000');
      expect(third.single.sessionId, 'session-160');
    } finally {
      await sql.close();
    }
  });
  test('recent pending replay cursor excludes years-old and decoded rows',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('recent-pending',
        database: sql, sqfliteFactory: databaseFactoryFfi);
    await db.open();
    final client = Client('recent-pending', databaseBuilder: (_) => db);
    await client.init();
    final room = Room(id: '!synthetic:example.test', client: client);
    client.rooms.add(room);
    Map<String, dynamic> raw(String id, int ts, String type) => {
          'event_id': id,
          'type': type,
          'sender': '@synthetic:example.test',
          'origin_server_ts': ts,
          'content': {
            'session_id': 'session',
            'sender_key': 'sender',
            'msgtype': 'm.text',
            'body': 'synthetic'
          }
        };
    try {
      for (var page = 0; page < 20; page++) {
        await db.commitRecoveryHistoryPage(room, 'seed', page, [
          for (var i = 0; i < 80; i++)
            raw('\$old-${page * 80 + i}', 1, EventTypes.Encrypted)
        ], {
          'revision': page + 1
        });
      }
      await db.commitRecoveryHistoryPage(room, 'seed', 20, [
        raw(r'$recent-a', 1000, EventTypes.Encrypted),
        raw(r'$recent-b', 1001, EventTypes.Encrypted),
        raw(r'$decoded', 1000, EventTypes.Message)
      ], {
        'revision': 21
      });
      final dynamic api = db;
      expect(
          await api.getRecoveryPendingEventIds(room,
              windowStart: 500, windowEnd: 2000, limit: 1),
          [r'$recent-a']);
      expect(
          await api.getRecoveryPendingEventIds(room,
              windowStart: 500,
              windowEnd: 2000,
              afterEventId: r'$recent-a',
              limit: 1),
          [r'$recent-b']);
    } finally {
      await client.dispose();
    }
  });
}
