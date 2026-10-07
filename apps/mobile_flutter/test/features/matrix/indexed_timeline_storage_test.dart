import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class StorageClient extends Client {
  StorageClient(this.store) : super('indexed-synthetic');
  final MatrixSdkDatabase store;
  @override
  DatabaseApi get database => store;
}

class ObservedSql extends Fake implements Database {
  ObservedSql(this.raw);
  final Database raw;
  int legacyBytes = 0;
  @override
  Batch batch() => raw.batch();
  @override
  Future<void> close() => raw.close();
  @override
  Future<int> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      raw.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);
  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      raw.delete(table, where: where, whereArgs: whereArgs);
  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? args]) =>
      raw.rawQuery(sql, args);
  @override
  Future<List<Map<String, Object?>>> query(String table,
      {bool? distinct,
      List<String>? columns,
      String? where,
      List<Object?>? whereArgs,
      String? groupBy,
      String? having,
      String? orderBy,
      int? limit,
      int? offset}) async {
    final rows = await raw.query(table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset);
    if (table == 'box_timeline_fragments') {
      for (final row in rows) {
        legacyBytes += (row['v'] as String?)?.length ?? 0;
      }
    }
    return rows;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  test('native bounded page never transfers the complete legacy order to UI',
      () async {
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final observed = ObservedSql(raw);
    final db = MatrixSdkDatabase('bounded-native', database: observed);
    await db.open();
    final room = Room(id: '!bounded:synthetic', client: StorageClient(db));
    try {
      await raw.insert('box_timeline_fragments', {
        'k': '${room.id}|',
        'v': jsonEncode(List.generate(10000, (i) => 'synthetic-$i')),
      });
      expect((await db.getEventIdList(room, limit: 30)).length, 30);
      expect(observed.legacyBytes, 0,
          reason: 'No full legacy order is admitted on UI');
    } finally {
      await db.close();
    }
  });
  test('SQLite compatibility page starts at requested retained ordinal',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('indexed-synthetic', database: sql);
    await db.open();
    final room = Room(id: '!indexed:synthetic', client: StorageClient(db));
    try {
      await sql.insert('box_timeline_fragments', {
        'k': '${room.id}|',
        'v': jsonEncode(['new', 'middle', 'old']),
      });
      expect(await db.getEventIdList(room, start: 1, limit: 1), ['middle']);
    } finally {
      await db.close();
    }
  });

  test('independent recovery cannot append an unproven newer head', () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('indexed-recovery', database: sql);
    await db.open();
    final room = Room(id: '!recovery:synthetic', client: StorageClient(db));
    try {
      await sql.insert('box_timeline_fragments', {
        'k': '${room.id}|',
        'v': jsonEncode(['old-head', 'old-tail']),
      });
      expect(
          await db.commitRecoveryHistoryPage(room, 'test', 0, [
            {
              'event_id': 'missing-new-head',
              'type': 'm.room.encrypted',
              'sender': '@synthetic:local',
              'origin_server_ts': 300,
              'content': <String, dynamic>{},
            }
          ], {
            'revision': 1
          }),
          isTrue);
      expect(await db.getEventIdList(room), ['old-head', 'old-tail']);
      expect(await db.getEventById('missing-new-head', room), isNotNull);
      expect((await db.getRecoveryCheckpoint('test'))?['revision'], 1);
      expect(await db.getRecoveryEventIds(room), ['missing-new-head']);
      Map<String, dynamic> recovered(String id) => {
            'event_id': id,
            'type': EventTypes.Encrypted,
            'sender': '@synthetic:local',
            'origin_server_ts': 200,
            'content': <String, dynamic>{},
          };
      expect(
          await db.commitRecoveryHistoryPage(
              room,
              'test',
              1,
              [recovered('missing-new-head'), recovered('recovered-tail')],
              {'revision': 2}),
          isTrue);
      expect(await db.getRecoveryEventIds(room, start: 1, limit: 1),
          ['recovered-tail']);
      expect(await db.getEventIdList(room), ['old-head', 'old-tail']);
      expect(
          await db.commitRecoveryHistoryPage(
              room, 'test', 1, [recovered('stale-page')], {'revision': 2}),
          isFalse);
      await expectLater(
          db.commitRecoveryHistoryPage(room, 'test', 2, [
            recovered('rolled-back'),
            <String, dynamic>{'event_id': 42}
          ], {
            'revision': 3
          }),
          throwsFormatException);
      expect(await db.getEventById('rolled-back', room), isNull);
      expect((await db.getRecoveryCheckpoint('test'))?['revision'], 2);
      expect(await db.getRecoveryEventIds(room),
          ['missing-new-head', 'recovered-tail']);
      await expectLater(
          db.getRecoveryEventIds(room, limit: 81), throwsArgumentError);
      await db.removeEvent('missing-new-head', room.id);
      expect(await db.getRecoveryEventIds(room), ['recovered-tail']);
      expect(await db.getEventIdList(room), ['old-head', 'old-tail']);
      await db.forgetRoom(room.id);
      expect(await db.getRecoveryEventIds(room), isEmpty);
      expect(await db.getEventById('recovered-tail', room), isNull);
    } finally {
      await db.close();
    }
  });
  test('same batch dedup and immutable lease survive head reset and removal',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('versions', database: sql);
    await db.open();
    final client = StorageClient(db);
    final room = Room(id: '!versions:synthetic', client: client);
    Future<void> add(String id) => db.storeEventUpdate(
        EventUpdate(roomID: room.id, type: EventUpdateType.timeline, content: {
          'event_id': id,
          'type': 'm.room.encrypted',
          'sender': '@synthetic:local',
          'origin_server_ts': 1,
          'content': <String, dynamic>{},
        }),
        client);
    try {
      await db.transaction(() async {
        await add('old');
        await add('middle');
        await add('new');
        await add('middle');
      });
      expect(await db.getTimelineEventCount(room), 3);
      final lease = await db.openTimelineIdSnapshot(room);
      final first = await lease.next(limit: 1);
      expect(first.ids, ['new']);
      expect(identical(await lease.next(limit: 1), first), isTrue);
      lease.accept(first);
      await db.transaction(() async {
        await db.removeEvent('middle', room.id);
        await db.deleteTimelineForRoom(room.id);
        await add('fresh');
      });
      expect(await db.getEventIdList(room), ['fresh']);
      final old = await lease.next(limit: 2);
      expect(old.ids, ['middle', 'old']);
      expect(old.hasMore, isFalse);
      lease.accept(old);
      lease.dispose();
      await expectLater(lease.next(), throwsStateError);
    } finally {
      await db.close();
    }
  });

  test('sync batch reads its staged count and requested positions', () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('batch-reads', database: sql);
    await db.open();
    final client = StorageClient(db);
    final room = Room(id: '!batch-reads:synthetic', client: client);
    Future<void> add(String id) => db.storeEventUpdate(
        EventUpdate(roomID: room.id, type: EventUpdateType.timeline, content: {
          'event_id': id,
          'type': 'm.room.encrypted',
          'sender': '@synthetic:local',
          'origin_server_ts': 1,
          'content': <String, dynamic>{},
        }),
        client);
    try {
      await db.prepareTimelineStorage([room.id]);
      await db.transaction(() async {
        await add('old');
        await add('new');
        await add('old');
        expect(await db.getTimelineEventCount(room), 2);
        final positions =
            await db.getTimelineEventPositions(room, ['old', 'new']);
        expect(positions.keys, unorderedEquals(['old', 'new']));
        expect(positions['new'], lessThan(positions['old']!));
        await db.removeEvent('old', room.id);
        expect(await db.getTimelineEventCount(room), 1);
        expect(await db.getTimelineEventPositions(room, ['old']), isEmpty);
        await db.deleteTimelineForRoom(room.id);
        await add('fresh');
        expect(await db.getTimelineEventCount(room), 1);
        expect(await db.getTimelineEventPositions(room, ['new', 'fresh']),
            {'fresh': -1});
      });
      expect(await db.getEventIdList(room), ['fresh']);
    } finally {
      await db.close();
    }
  });
  test('failed batch does not expose staged order or event body', () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('rollback', database: sql);
    await db.open();
    final client = StorageClient(db),
        room = Room(id: '!rollback:synthetic', client: StorageClient(db));
    try {
      await expectLater(db.transaction(() async {
        await db.storeEventUpdate(
            EventUpdate(
                roomID: room.id,
                type: EventUpdateType.timeline,
                content: {
                  'event_id': 'aborted',
                  'type': 'm.room.encrypted',
                  'sender': '@synthetic:local',
                  'origin_server_ts': 1,
                  'content': <String, dynamic>{},
                }),
            client);
        throw StateError('synthetic rollback');
      }), throwsStateError);
      expect(await db.getTimelineEventCount(room), 0);
      expect(await db.getEventById('aborted', room), isNull);
    } finally {
      await db.close();
    }
  });

  test('clear and forget cannot resurrect ready indexed metadata', () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('forget', database: sql);
    await db.open();
    final room = Room(id: '!forget:synthetic', client: StorageClient(db));
    try {
      await sql.insert(
          'box_timeline_fragments', {'k': '${room.id}|', 'v': '["retained"]'});
      expect(await db.getTimelineEventCount(room), 1);
      await db.forgetRoom(room.id);
      expect(await db.getTimelineEventCount(room), 0);
      await db.clear();
      expect(await db.getTimelineEventCount(room), 0);
    } finally {
      await db.close();
    }
  });

  test(
      'explicit legacy export includes current indexed authority and reimports',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('legacy-export', database: sql);
    await db.open();
    final client = StorageClient(db),
        room = Room(id: '!export:synthetic', client: StorageClient(db));
    try {
      await db.transaction(() async {
        await db.storeEventUpdate(
            EventUpdate(
                roomID: room.id,
                type: EventUpdateType.timeline,
                content: {
                  'event_id': 'current',
                  'type': 'm.room.encrypted',
                  'sender': '@synthetic:local',
                  'origin_server_ts': 1,
                  'content': <String, dynamic>{}
                }),
            client);
      });
      final dump = await db.exportDump();
      final decoded = jsonDecode(dump) as Map;
      expect((decoded['box_timeline_fragments'] as Map)['${room.id}|'],
          ['current']);
      expect(await db.importDump(dump), isTrue);
      expect(await db.getEventIdList(room), ['current']);
      expect(await db.getEventById('current', room), isNotNull);
    } finally {
      await db.close();
    }
  });

  test('captured sparse revision advances at most requested raw positions',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('sparse', database: sql);
    await db.open();
    final client = StorageClient(db),
        room = Room(id: '!sparse:synthetic', client: StorageClient(db));
    try {
      await sql.insert('box_timeline_fragments', {
        'k': '${room.id}|',
        'v': jsonEncode(List.generate(1000, (i) => 'id-$i'))
      });
      await db.prepareTimelineStorage([room.id]);
      await db.transaction(() async {
        for (var i = 0; i < 999; i++) {
          await db.removeEvent('id-$i', room.id);
        }
      });
      final lease = await db.openTimelineIdSnapshot(room);
      await db.transaction(() => db.storeEventUpdate(
          EventUpdate(
              roomID: room.id,
              type: EventUpdateType.timeline,
              content: {
                'event_id': 'new-head',
                'type': 'm.room.encrypted',
                'sender': '@synthetic:local',
                'origin_server_ts': 1,
                'content': <String, dynamic>{}
              }),
          client));
      final first = await lease.next(limit: 2);
      expect(first.ids, isEmpty,
          reason:
              'A captured revision must not scan999 retired rows for one visible ID');
      expect(first.hasMore, isTrue);
      expect(first.cursor, 1);
      lease.accept(first);
      final found = <String>[];
      var pages = 1;
      while (true) {
        final page = await lease.next(limit: 256);
        pages++;
        found.addAll(page.ids);
        lease.accept(page);
        if (!page.hasMore) break;
      }
      expect(found, ['id-999']);
      expect(pages, lessThanOrEqualTo(6));
      lease.dispose();
    } finally {
      await db.close();
    }
  });

  test('old to new fork stays inside captured epoch after live reset',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('fork', database: sql);
    await db.open();
    final room = Room(id: '!fork:synthetic', client: StorageClient(db));
    try {
      await sql.insert('box_timeline_fragments',
          {'k': '${room.id}|', 'v': '["new","middle","old"]'});
      final lease = await db.openTimelineIdSnapshot(room);
      await db.deleteTimelineForRoom(room.id);
      final child = await lease.fork(
          afterEventId: 'old', direction: TimelineIdDirection.newer);
      lease.dispose();
      final page = await child.next(limit: 2);
      expect(page.ids, ['middle', 'new']);
      expect(page.hasMore, isFalse);
      child.accept(page);
      child.dispose();
    } finally {
      await db.close();
    }
  });

  test(
      'search checkpoint retries frozen multi-page IDs after missing payload and reset',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('search-checkpoint', database: sql);
    await db.open();
    final room =
        Room(id: '!search-checkpoint:synthetic', client: StorageClient(db));
    try {
      await sql.insert(
          'box_timeline_fragments', {'k': '${room.id}|', 'v': '["a","b","c"]'});
      for (final id in ['a', 'b']) {
        await sql.insert('box_events', {
          'k': '${room.id}|$id',
          'v': jsonEncode({
            'event_id': id,
            'type': 'm.room.encrypted',
            'sender': '@synthetic:local',
            'origin_server_ts': 1,
            'content': <String, dynamic>{},
          })
        });
      }
      var active = await db.openSearchEventIds(room);
      final saved = await active.checkpoint();
      try {
        for (var offset = 0; active.hasMore;) {
          final ids = await active.page(offset, 1);
          final events = await db.getSearchEventsByIds(room, ids);
          if (events.any((e) => e == null)) {
            throw StateError('Synthetic payload unavailable');
          }
          offset = active.nextOffset;
        }
        fail('Expected missing retained payload');
      } on StateError {
        active.dispose();
        active = saved;
      }
      await db.deleteTimelineForRoom(room.id);
      await db.commitRecoveryHistoryPage(room, 'search-retry', 0, [
        {
          'event_id': 'c',
          'type': 'm.room.encrypted',
          'sender': '@synthetic:local',
          'origin_server_ts': 1,
          'content': <String, dynamic>{},
        }
      ], {
        'revision': 1
      });
      final result = <String>[];
      while (active.hasMore) {
        final ids = await active.page(active.nextOffset, 1);
        result.addAll(ids);
        expect(
            (await db.getSearchEventsByIds(room, ids)).every((e) => e != null),
            isTrue);
      }
      expect(result, ['a', 'b', 'c']);
      active.dispose();
    } finally {
      await db.close();
    }
  });
  test(
      'retained search covers disconnected and recovery bodies without chat splice',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('retained-search', database: sql);
    await db.open();
    final client = StorageClient(db);
    final room = Room(id: '!retained-search:synthetic', client: client);
    Map<String, dynamic> event(String id, int ts) => {
          'event_id': id,
          'type': 'm.room.encrypted',
          'sender': '@synthetic:local',
          'origin_server_ts': ts,
          'content': <String, dynamic>{}
        };
    Future<void> add(String id, int ts) => db.transaction(() =>
        db.storeEventUpdate(
            EventUpdate(
                roomID: room.id,
                type: EventUpdateType.timeline,
                content: event(id, ts)),
            client));
    Future<List<String>> collect(MatrixSearchEventIds search) async {
      final result = <String>[];
      while (search.hasMore) {
        result.addAll(await search.page(search.nextOffset, 2));
      }
      return result;
    }

    try {
      await add('archived', 10);
      await db.deleteTimelineForRoom(room.id);
      await add('current', 20);
      await db.commitRecoveryHistoryPage(
          room, 'retained', 0, [event('recovered-head', 30)], {'revision': 1});
      expect(await db.getEventIdList(room), ['current']);
      final search = await db.openSearchEventIds(room);

      expect(await collect(search), ['recovered-head', 'current', 'archived']);
      search.dispose();
    } finally {
      await db.close();
    }
  });

  test(
      'retained search freezes ordering across timestamp promotion and deletion',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('retained-versions', database: sql);
    await db.open();
    final client = StorageClient(db),
        room =
            Room(id: '!retained-versions:synthetic', client: StorageClient(db));
    Future<void> add(String id, int? ts) =>
        db.transaction(() => db.storeEventUpdate(
            EventUpdate(
                roomID: room.id,
                type: EventUpdateType.timeline,
                content: {
                  'event_id': id,
                  'type': 'm.room.encrypted',
                  'sender': '@synthetic:local',
                  if (ts != null) 'origin_server_ts': ts,
                  'content': <String, dynamic>{}
                }),
            client));
    Future<List<String>> collect(MatrixSearchEventIds s) async {
      final ids = <String>[];
      while (s.hasMore) {
        ids.addAll(await s.page(s.nextOffset, 1));
      }
      return ids;
    }

    try {
      await add('unknown', null);
      await add('known', 10);
      final frozen = await db.openSearchEventIds(room);
      final backup = await frozen.checkpoint();
      await add('unknown', 30);
      await db.removeEvent('known', room.id);
      expect(await collect(frozen), ['known', 'unknown']);
      expect(await collect(backup), ['known', 'unknown']);
      frozen.dispose();
      backup.dispose();
      final current = await db.openSearchEventIds(room);
      expect(await collect(current), ['unknown']);
      current.dispose();
    } finally {
      await db.close();
    }
  });
  test(
      'search readiness permits bounded epoch cleanup only after last timeline lease',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('lease-gc', database: sql);
    await db.open();
    final client = StorageClient(db),
        room = Room(id: '!lease-gc:synthetic', client: StorageClient(db));
    Future<void> add(String id, int ts) => db.storeEventUpdate(
        EventUpdate(roomID: room.id, type: EventUpdateType.timeline, content: {
          'event_id': id,
          'origin_server_ts': ts,
          'sender': '@synthetic:local',
          'type': 'm.room.encrypted',
          'content': <String, dynamic>{}
        }),
        client);
    Future<int> oldRows() async => (await sql.rawQuery(
            'SELECT COUNT(*) AS n FROM matrix_timeline_fragment_ids '
            'WHERE fragment_key=? AND epoch=1',
            ['${room.id}|']))
        .single['n'] as int;
    try {
      await add('archived', 1);
      final parent = await db.openTimelineIdSnapshot(room);
      final child = await parent.checkpoint();
      parent.dispose();
      await db.deleteTimelineForRoom(room.id);
      await add('current', 2);
      final firstSearch = await db.openSearchEventIds(room);
      firstSearch.dispose();
      expect(await oldRows(), 1);
      expect((await child.next()).ids, ['archived']);
      child.dispose();
      final search = await db.openSearchEventIds(room);
      expect(await oldRows(), 0);
      final result = <String>[];
      while (search.hasMore) {
        result.addAll(await search.page(search.nextOffset, 256));
      }
      expect(result, ['current', 'archived']);
      search.dispose();
    } finally {
      await db.close();
    }
  });
  test('retained search never promotes an abandoned partial migration epoch',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    var first = true;
    final db = MatrixSdkDatabase('abandoned-search', database: sql,
        timelineMigrationReader: (key) async* {
      if (first) {
        first = false;
        yield ['abandoned'];
        await sql.update('box_timeline_fragments', {'v': '["kept"]'},
            where: 'k=?', whereArgs: [key]);
        throw StateError('Synthetic interrupted source replacement');
      }
      yield ['kept'];
    });
    await db.open();
    final room =
        Room(id: '!abandoned-search:synthetic', client: StorageClient(db));
    try {
      await sql.insert(
          'box_timeline_fragments', {'k': '${room.id}|', 'v': '["abandoned"]'});
      await expectLater(db.getTimelineEventCount(room), throwsStateError);
      expect(await db.getEventIdList(room), ['kept']);
      final search = await db.openSearchEventIds(room);
      final found = <String>[];
      while (search.hasMore) {
        found.addAll(await search.page(search.nextOffset, 256));
      }
      expect(found, ['kept']);
      search.dispose();
    } finally {
      await db.close();
    }
  });
  test('retired search versions wait for last checkpoint lease then clean up',
      () async {
    final sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('search-version-gc', database: sql);
    await db.open();
    final client = StorageClient(db),
        room =
            Room(id: '!search-version-gc:synthetic', client: StorageClient(db));
    Future<void> add(String id, int ts) => db.storeEventUpdate(
        EventUpdate(roomID: room.id, type: EventUpdateType.timeline, content: {
          'event_id': id,
          'origin_server_ts': ts,
          'sender': '@synthetic:local',
          'type': 'm.room.encrypted',
          'content': <String, dynamic>{}
        }),
        client);
    Future<int> retired() async => (await sql.rawQuery(
            'SELECT COUNT(*) AS n FROM matrix_retained_search_rows '
            'WHERE room_id=? AND valid_to IS NOT NULL',
            [room.id]))
        .single['n'] as int;
    Future<List<String>> collect(MatrixSearchEventIds snapshot) async {
      final ids = <String>[];
      while (snapshot.hasMore) {
        ids.addAll(await snapshot.page(snapshot.nextOffset, 256));
      }
      return ids;
    }

    try {
      await add('a', 1);
      await add('b', 2);
      final parent = await db.openSearchEventIds(room),
          child = await parent.checkpoint();
      parent.dispose();
      await add('a', 3);
      final current = await db.openSearchEventIds(room);
      expect(await collect(current), ['a', 'b']);
      current.dispose();
      expect(await retired(), 1);
      expect(await collect(child), ['b', 'a']);
      child.dispose();
      final latest = await db.openSearchEventIds(room);
      latest.dispose();
      for (var i = 0; i < 100 && await retired() != 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(await retired(), 0);
      expect(
          (await sql.rawQuery(
                  'SELECT COUNT(*) AS n FROM matrix_retained_search_rows '
                  'WHERE room_id=? AND valid_to IS NULL',
                  [room.id]))
              .single['n'],
          2);
    } finally {
      await db.close();
    }
  });
}
