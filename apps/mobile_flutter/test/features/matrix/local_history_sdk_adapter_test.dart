import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/local_room_history_search.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/features/matrix/room_history_day_index.dart';

class LocalClient extends Client {
  LocalClient(this.store) : super('synthetic-local-adapter');
  final MatrixSdkDatabase store;
  late Room room;
  @override
  DatabaseApi get database => store;
  @override
  Room? getRoomById(String id) => id == room.id ? room : null;
}

class _PageGateDatabase extends Fake implements Database {
  _PageGateDatabase(this.delegate);
  final Database delegate;
  final sizeRead = Completer<void>();
  final releasePage = Completer<void>();
  bool gateNextPage = false;
  bool disableJson = false;
  bool disableJsonEach = false;

  @override
  Batch batch() => delegate.batch();
  @override
  Future<void> close() => delegate.close();
  @override
  Future<int> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      delegate.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);
  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      delegate.delete(table, where: where, whereArgs: whereArgs);
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
          int? offset}) =>
      delegate.query(table,
          distinct: distinct,
          columns: columns,
          where: where,
          whereArgs: whereArgs,
          groupBy: groupBy,
          having: having,
          orderBy: orderBy,
          limit: limit,
          offset: offset);
  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
      [List<Object?>? arguments]) async {
    if (disableJson && sql.contains('json_array_length')) {
      throw Exception('no such function: json_array_length');
    }
    if (disableJsonEach && sql.contains('json_each')) {
      throw Exception('no such table: json_each');
    }
    final rows = await delegate.rawQuery(sql, arguments);
    if (gateNextPage && sql.contains('AS item_count\nFROM')) {
      gateNextPage = false;
      sizeRead.complete();
      await releasePage.future;
    }
    return rows;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  test('frozen ID pages ignore new heads and batch reads retain holes',
      () async {
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase(inMemoryDatabasePath,
        database: raw, sqfliteFactory: databaseFactoryFfi);
    await db.open();
    final client = LocalClient(db);
    final room =
        client.room = Room(id: '!search-snapshot:local', client: client);
    Future<void> store(int i) => db.storeEventUpdate(
        EventUpdate(roomID: room.id, type: EventUpdateType.timeline, content: {
          'event_id': 'e$i',
          'sender': '@synthetic:local',
          'type': EventTypes.Message,
          'origin_server_ts':
              DateTime.utc(2026, 9, i + 1).millisecondsSinceEpoch,
          'content': {'msgtype': MessageTypes.Text, 'body': 'needle $i'}
        }),
        client);
    try {
      for (var i = 0; i < 4; i++) {
        await store(i);
      }
      final ids = await db.openSearchEventIds(room, maxBytes: 8);
      try {
        expect(await ids.page(0, 2), ['e3', 'e2']);
        await store(4);
        expect(await ids.page(2, 2), ['e1', 'e0']);
        final originalFragment = (await raw.query('box_timeline_fragments'))
            .singleWhere((row) =>
                (jsonDecode(row['v'] as String) as List).contains('e2'));
        final originalIds =
            (jsonDecode(originalFragment['v'] as String) as List)
                .cast<String>();
        Future<void> replaceFragment(List<String> values) async {
          await raw.update('box_timeline_fragments', {'v': jsonEncode(values)},
              where: 'k = ?', whereArgs: [originalFragment['k']]);
          await db.open();
        }

        final inserted = await db.openSearchEventIds(room, maxBytes: 8);
        try {
          expect(await inserted.page(0, 2), ['e4', 'e3']);
          await replaceFragment([
            ...originalIds.take(3),
            'interior-insert',
            ...originalIds.skip(3)
          ]);
          await expectLater(inserted.page(2, 2),
              throwsA(isA<MatrixSearchSnapshotInvalidated>()));
        } finally {
          inserted.dispose();
          await replaceFragment(originalIds);
        }

        final deleted = await db.openSearchEventIds(room, maxBytes: 8);
        try {
          expect(await deleted.page(0, 2), ['e4', 'e3']);
          await replaceFragment(originalIds.where((id) => id != 'e1').toList());
          await expectLater(deleted.page(2, 2),
              throwsA(isA<MatrixSearchSnapshotInvalidated>()));
        } finally {
          deleted.dispose();
          await replaceFragment(originalIds);
        }
        final stored = await raw.query('box_events');
        final missing = stored.singleWhere(
            (r) => (jsonDecode(r['v'] as String) as Map)['event_id'] == 'e2');
        await raw
            .delete('box_events', where: 'k = ?', whereArgs: [missing['k']]);
        await db.open();
        final rows = await db.getSearchEventsByIds(room, ['e3', 'e2']);
        expect(rows.map((e) => e?.eventId), ['e3', null]);
        expect(await ids.page(2, 2), ['e1', 'e0'],
            reason: 'event-row holes must not shift frozen timeline IDs');
        final fragments = await raw.query('box_timeline_fragments');
        final fragment = fragments.singleWhere(
            (row) => (jsonDecode(row['v'] as String) as List).contains('e2'));
        final changedIds = (jsonDecode(fragment['v'] as String) as List)
            .where((id) => id != 'e2')
            .toList();
        await raw.update(
            'box_timeline_fragments', {'v': jsonEncode(changedIds)},
            where: 'k = ?', whereArgs: [fragment['k']]);
        await db.open();
        await expectLater(
            ids.page(2, 2), throwsA(isA<MatrixSearchSnapshotInvalidated>()),
            reason: 'a vanished checkpoint must invalidate low-memory paging');
      } finally {
        ids.dispose();
      }
    } finally {
      await db.close();
      await client.dispose();
    }
  });
  test('one search budget bounds room snapshots and sees SQL fragment changes',
      () async {
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase(inMemoryDatabasePath,
        database: raw, sqfliteFactory: databaseFactoryFfi);
    await db.open();
    final client = LocalClient(db);
    final firstRoom =
        client.room = Room(id: '!first-search:local', client: client);
    final secondRoom = Room(id: '!second-search:local', client: client);
    Future<void> store(int i) => db.storeEventUpdate(
        EventUpdate(
            roomID: firstRoom.id,
            type: EventUpdateType.timeline,
            content: {
              'event_id': 'a$i',
              'sender': '@synthetic:local',
              'type': EventTypes.Message,
              'origin_server_ts':
                  DateTime.utc(2026, 9, i + 1).millisecondsSinceEpoch,
              'content': {'msgtype': MessageTypes.Text, 'body': 'fixture'}
            }),
        client);
    try {
      for (var i = 0; i < 4; i++) {
        await store(i);
      }
      final secondKey = TupleKey(secondRoom.id, '').toString();
      await raw.insert('box_timeline_fragments', {
        'k': secondKey,
        'v': jsonEncode(['b3', 'b2', 'b1', 'b0'])
      });
      await db.open();
      final budget = MatrixSearchSnapshotBudget(maxBytes: 90);
      final first = await db.openSearchEventIds(firstRoom, budget: budget);
      final second = await db.openSearchEventIds(secondRoom, budget: budget);
      try {
        expect(budget.retainedBytes, greaterThan(0));
        expect(budget.retainedBytes, lessThanOrEqualTo(90));
        expect(await first.page(0, 2), ['a3', 'a2']);
        await raw.update(
            'box_timeline_fragments',
            {
              'v': jsonEncode(['b3', 'b2', 'inserted', 'b1', 'b0'])
            },
            where: 'k = ?',
            whereArgs: [secondKey]);
        await expectLater(
            second.page(0, 2), throwsA(isA<MatrixSearchSnapshotInvalidated>()),
            reason: 'fallback must read encrypted SQL, not a stale Box cache');
      } finally {
        first.dispose();
        second.dispose();
      }
      expect(budget.retainedBytes, 0);
    } finally {
      await db.close();
      await client.dispose();
    }
  });
  test('native search opens the committed fragment during a receive batch',
      () async {
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase(inMemoryDatabasePath,
        database: raw, sqfliteFactory: databaseFactoryFfi);
    await db.open();
    final client = LocalClient(db);
    final room =
        client.room = Room(id: '!pending-search:local', client: client);
    Future<void> store(String id) => db.storeEventUpdate(
        EventUpdate(roomID: room.id, type: EventUpdateType.timeline, content: {
          'event_id': id,
          'sender': '@synthetic:local',
          'type': EventTypes.Message,
          'origin_server_ts': 1,
          'content': {'msgtype': MessageTypes.Text, 'body': 'fixture'}
        }),
        client);
    try {
      await store('committed');
      await db.transaction(() async {
        await store('pending');
        final snapshot = await db.openSearchEventIds(room);
        try {
          expect(await snapshot.page(0, 5), ['committed'],
              reason: 'metadata and fixed IDs must share committed SQL state');
        } finally {
          snapshot.dispose();
        }
      });
      final afterCommit = await db.openSearchEventIds(room);
      try {
        expect(await afterCommit.page(0, 5), ['pending', 'committed']);
      } finally {
        afterCommit.dispose();
      }
    } finally {
      await db.close();
      await client.dispose();
    }
  });
  test('head append cannot split the two SQL reads of one search page',
      () async {
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final gated = _PageGateDatabase(raw);
    final db = MatrixSdkDatabase(inMemoryDatabasePath,
        database: gated, sqfliteFactory: databaseFactoryFfi);
    await db.open();
    final client = LocalClient(db);
    final room = client.room = Room(id: '!gated-page:local', client: client);
    Future<void> store(String id) => db.storeEventUpdate(
        EventUpdate(roomID: room.id, type: EventUpdateType.timeline, content: {
          'event_id': id,
          'sender': '@synthetic:local',
          'type': EventTypes.Message,
          'origin_server_ts': 1,
          'content': {'msgtype': MessageTypes.Text, 'body': 'fixture'}
        }),
        client);
    try {
      for (var i = 0; i < 4; i++) {
        await store('e$i');
      }
      final snapshot = await db.openSearchEventIds(room, maxBytes: 1);
      try {
        gated.gateNextPage = true;
        final page = snapshot.page(0, 2);
        await gated.sizeRead.future;
        var appendDone = false;
        final append = db.transaction(() => store('e4')).then((_) {
          appendDone = true;
        });
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final appendFinishedInsidePage = appendDone;
        gated.releasePage.complete();
        expect(await page, ['e3', 'e2']);
        await append;
        expect(appendFinishedInsidePage, isFalse,
            reason: 'the page SQL reads must share the SDK transaction gate');
        expect(await snapshot.page(2, 2), ['e1', 'e0']);
      } finally {
        if (!gated.releasePage.isCompleted) gated.releasePage.complete();
        snapshot.dispose();
      }
    } finally {
      await db.close();
      await client.dispose();
    }
  });
  test('missing JSON1 uses bounded fixed IDs and fails closed when oversized',
      () async {
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final gated = _PageGateDatabase(raw);
    final db = MatrixSdkDatabase(inMemoryDatabasePath,
        database: gated, sqfliteFactory: databaseFactoryFfi);
    await db.open();
    final client = LocalClient(db);
    final room = client.room = Room(id: '!no-json1:local', client: client);
    try {
      await db.storeEventUpdate(
          EventUpdate(
              roomID: room.id,
              type: EventUpdateType.timeline,
              content: {
                'event_id': 'e0',
                'sender': '@synthetic:local',
                'type': EventTypes.Message,
                'origin_server_ts': 1,
                'content': {'msgtype': MessageTypes.Text, 'body': 'fixture'}
              }),
          client);
      gated.disableJson = true;
      final small = await db.openSearchEventIds(room);
      try {
        expect(await small.page(0, 5), ['e0']);
      } finally {
        small.dispose();
      }
      await expectLater(db.openSearchEventIds(room, maxBytes: 1),
          throwsA(isA<MatrixSearchBackendUnavailable>()));
      gated.disableJson = false;
      final oversized = await db.openSearchEventIds(room, maxBytes: 1);
      gated.disableJsonEach = true;
      try {
        await expectLater(oversized.page(0, 1),
            throwsA(isA<MatrixSearchBackendUnavailable>()));
      } finally {
        oversized.dispose();
      }
    } finally {
      await db.close();
      await client.dispose();
    }
  });
  test(
      'actual SDK database holes retain raw offsets and date/search remain local',
      () async {
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase(inMemoryDatabasePath,
        database: raw, sqfliteFactory: databaseFactoryFfi);
    await db.open();
    final client = LocalClient(db);
    final room = client.room = Room(id: '!synthetic:local', client: client);
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.invalid'),
        readContinuityMetadata: (c) async => MatrixClientContinuityMetadata(
            isLoggedIn: c.isLogged(),
            userId: c.userID,
            deviceId: c.deviceID,
            ed25519Fingerprint: 'synthetic',
            databaseGeneration: 'synthetic'));
    MatrixRoomLease? lease;
    try {
      for (var i = 0; i < 4; i++) {
        await db.storeEventUpdate(
            EventUpdate(
                roomID: room.id,
                type: EventUpdateType.timeline,
                content: {
                  'event_id': 'e$i',
                  'sender': '@synthetic:local',
                  'type': EventTypes.Message,
                  'origin_server_ts':
                      DateTime(2026, 9, i + 1).millisecondsSinceEpoch,
                  'content': {
                    'msgtype': MessageTypes.Text,
                    'body': 'synthetic needle $i'
                  }
                }),
            client);
      }
      final ids = await db.getEventIdList(room);
      final first = ids.first;
      final stored = await raw.query('box_events');
      final missing = stored.singleWhere(
          (r) => (jsonDecode(r['v'] as String) as Map)['event_id'] == first);
      await raw.delete('box_events', where: 'k = ?', whereArgs: [missing['k']]);
      // Reopen box wrappers to reproduce a persisted missing row without the
      // SDK's storeEventUpdate in-memory cache masking the disk hole.
      await db.open();
      lease = await owner.openRoomLease(room.id);
      final budget = MatrixSearchSnapshotBudget(maxBytes: 100);
      final frozen = await lease.openLocalSearchIds(room.id, budget: budget);
      try {
        expect(budget.retainedBytes, greaterThan(0));
        expect(await frozen.page(0, 2), ids.take(2).toList());
        final keyed =
            await lease.readLocalSearchByIds(room.id, ids.take(2).toList());
        expect(keyed.map((e) => e.eventId), ids.take(2));
        expect(keyed.first.isDisplayable, isFalse);
      } finally {
        frozen.dispose();
      }
      expect(budget.retainedBytes, 0);
      final page = await lease.readLocalSearchPage(room.id, 0, 2);
      expect(page, hasLength(2));
      expect(page.first.eventId, first);
      expect(page.first.isDisplayable, isFalse);
      final search = LocalRoomHistorySearch(
          roomIds: () => [room.id],
          readPage: lease.readLocalSearchPage,
          sourceRevision: () => lease!.localHistorySearchRevision,
          snapshot: lease.localHistorySnapshot,
          project: (_, row) => row.visibleText.isEmpty ? null : row);
      final result =
          await search.search(const ChatSearchFilters(keyword: 'needle'));
      expect(result.items, hasLength(3));
      expect(result.coverageIncomplete, isTrue);
      final month =
          await lease.loadLocalHistoryMonthDays(const CalendarMonth(2026, 9));
      expect(
          month.anchors.values.toSet(), ids.where((id) => id != first).toSet());
      expect(lease.notificationRoomIds, [room.id]);
    } finally {
      await lease?.cancel();
      await db.close();
      await client.dispose();
    }
  });
}
