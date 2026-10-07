import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/local_room_history_search.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/features/matrix/room_history_day_index.dart';

import 'fixtures/delegating_sqlite_database.dart';

class LocalClient extends Client {
  LocalClient(this.store) : super('synthetic-local-adapter');
  final MatrixSdkDatabase store;
  late Room room;
  @override
  DatabaseApi get database => store;
  @override
  Room? getRoomById(String id) => id == room.id ? room : null;
}

class _PageGateDatabase extends DelegatingSqliteDatabase {
  _PageGateDatabase(super.delegate);
  final pageRead = Completer<void>();
  final releasePage = Completer<void>();
  bool gateNextPage = false;
  bool disableJson = false;
  bool disableJsonEach = false;
  bool failNextIndexedPage = false;
  int jsonCalls = 0;

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
      [List<Object?>? arguments]) async {
    if (disableJson && sql.contains('json_array_length')) {
      jsonCalls++;
      throw StateError('no such function: json_array_length');
    }
    if (disableJsonEach && sql.contains('json_each')) {
      jsonCalls++;
      throw StateError('no such table: json_each');
    }
    final indexedPage =
        sql.startsWith('SELECT * FROM matrix_retained_search_rows ');
    if (indexedPage && failNextIndexedPage) {
      failNextIndexedPage = false;
      throw StateError('Synthetic indexed storage unavailable');
    }
    final rows = await delegate.rawQuery(sql, arguments);
    if (gateNextPage && indexedPage) {
      gateNextPage = false;
      pageRead.complete();
      await releasePage.future;
    }
    return rows;
  }
}

Future<void> _store(MatrixSdkDatabase db, Client client, Room room, String id,
        int timestamp) =>
    db.storeEventUpdate(
        EventUpdate(roomID: room.id, type: EventUpdateType.timeline, content: {
          'event_id': id,
          'sender': '@synthetic:local',
          'type': EventTypes.Message,
          'origin_server_ts': timestamp,
          'content': {'msgtype': MessageTypes.Text, 'body': 'needle $id'}
        }),
        client);

Future<List<String>> _remaining(MatrixSearchEventIds ids,
    {int pageSize = 2}) async {
  final result = <String>[];
  while (ids.hasMore) {
    final offset = ids.nextOffset;
    result.addAll(await ids.page(offset, pageSize));
    expect(ids.lastRawCount, lessThanOrEqualTo(pageSize));
    if (ids.hasMore) expect(ids.nextOffset, greaterThan(offset));
  }
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  test('frozen ID pages survive source changes and batch reads retain holes',
      () async {
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase(inMemoryDatabasePath,
        database: raw, sqfliteFactory: databaseFactoryFfi);
    await db.open();
    final client = LocalClient(db);
    final room =
        client.room = Room(id: '!search-snapshot:local', client: client);
    try {
      for (var i = 0; i < 4; i++) {
        await _store(db, client, room, 'e$i', (i + 1) * 100);
      }
      final ids = await db.openSearchEventIds(room, maxBytes: 8);
      MatrixSearchEventIds? saved;
      try {
        expect(await ids.page(0, 2), ['e3', 'e2']);
        saved = await ids.checkpoint();
        await _store(db, client, room, 'e4', 500);
        await _store(db, client, room, 'interior-insert', 250);
        await _store(db, client, room, 'e1', 210);
        await db.removeEvent('e2', room.id);
        // A persisted payload hole is different from removing its search ID.
        await raw.delete('box_events',
            where: 'k = ?', whereArgs: [TupleKey(room.id, 'e0').toString()]);
        expect(
            (await db.getSearchEventsByIds(room, ['e3', 'e0']))
                .map((event) => event?.eventId),
            ['e3', null]);
        expect(await _remaining(ids), ['e1', 'e0']);
        expect(await _remaining(saved), ['e1', 'e0'],
            reason:
                'checkpoint keeps its captured revision across edits/deletes');
        final current = await db.openSearchEventIds(room, maxBytes: 8);
        try {
          expect(await _remaining(current),
              ['e4', 'e3', 'interior-insert', 'e1', 'e0']);
          await expectLater(current.page(0, 2),
              throwsA(isA<MatrixSearchSnapshotInvalidated>()),
              reason:
                  'an unsupported rewind must fail rather than change snapshots');
        } finally {
          current.dispose();
        }
      } finally {
        saved?.dispose();
        ids.dispose();
      }
      await expectLater(ids.page(0, 2), throwsStateError);
    } finally {
      await db.close();
      await client.dispose();
    }
  });

  test(
      'two native readers retain metadata while revisions change independently',
      () async {
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase(inMemoryDatabasePath,
        database: raw, sqfliteFactory: databaseFactoryFfi);
    await db.open();
    final client = LocalClient(db);
    final firstRoom =
        client.room = Room(id: '!first-search:local', client: client);
    final secondRoom = Room(id: '!second-search:local', client: client);
    try {
      for (var i = 0; i < 4; i++) {
        await _store(db, client, firstRoom, 'a$i', i + 1);
        await _store(db, client, secondRoom, 'b$i', i + 1);
      }
      final budget = MatrixSearchSnapshotBudget(maxBytes: 1);
      final first = await db.openSearchEventIds(firstRoom, budget: budget);
      final second = await db.openSearchEventIds(secondRoom, budget: budget);
      try {
        expect(budget.retainedBytes, 0,
            reason: 'indexed handles do not copy room-sized ID arrays');
        expect(await first.page(0, 2), ['a3', 'a2']);
        await _store(db, client, secondRoom, 'inserted', 5);
        await db.removeEvent('b1', secondRoom.id);
        expect(await _remaining(second), ['b3', 'b2', 'b1', 'b0']);
        expect(await _remaining(first), ['a1', 'a0']);
        final fresh = await db.openSearchEventIds(secondRoom, budget: budget);
        try {
          expect(await _remaining(fresh), ['inserted', 'b3', 'b2', 'b0']);
        } finally {
          fresh.dispose();
        }
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

  test('prepared native search captures committed IDs during a receive batch',
      () async {
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase(inMemoryDatabasePath,
        database: raw, sqfliteFactory: databaseFactoryFfi);
    await db.open();
    final client = LocalClient(db);
    final room =
        client.room = Room(id: '!pending-search:local', client: client);
    try {
      await _store(db, client, room, 'committed', 1);
      // Lazy backfill belongs outside the atomic receive transaction.
      final prepared = await db.openSearchEventIds(room);
      prepared.dispose();
      await db.transaction(() async {
        await _store(db, client, room, 'pending', 2);
        final snapshot = await db.openSearchEventIds(room);
        try {
          expect(await _remaining(snapshot), ['committed'],
              reason: 'immutable search metadata captures committed SQL state');
        } finally {
          snapshot.dispose();
        }
      });
      final afterCommit = await db.openSearchEventIds(room);
      try {
        expect(await _remaining(afterCommit), ['pending', 'committed']);
      } finally {
        afterCommit.dispose();
      }
    } finally {
      await db.close();
      await client.dispose();
    }
  });

  test('head append cannot interleave with a native search page gate',
      () async {
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final gated = _PageGateDatabase(raw);
    final db = MatrixSdkDatabase(inMemoryDatabasePath,
        database: gated, sqfliteFactory: databaseFactoryFfi);
    await db.open();
    final client = LocalClient(db);
    final room = client.room = Room(id: '!gated-page:local', client: client);
    try {
      for (var i = 0; i < 4; i++) {
        await _store(db, client, room, 'e$i', i + 1);
      }
      final snapshot = await db.openSearchEventIds(room, maxBytes: 1);
      final peer = await db.openSearchEventIds(room, maxBytes: 1);
      try {
        gated.gateNextPage = true;
        final page = snapshot.page(0, 2);
        await gated.pageRead.future.timeout(const Duration(seconds: 2));
        var peerDone = false, appendDone = false;
        final peerPage = peer.page(0, 2).then((value) {
          peerDone = true;
          return value;
        });
        final append =
            db.transaction(() => _store(db, client, room, 'e4', 5)).then((_) {
          appendDone = true;
        });
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(peerDone, isFalse);
        expect(appendDone, isFalse);
        gated.releasePage.complete();
        expect(await page, ['e3', 'e2']);
        expect(await peerPage, ['e3', 'e2']);
        await append;
        expect(await _remaining(snapshot), ['e1', 'e0']);
        expect(await _remaining(peer), ['e1', 'e0']);
      } finally {
        if (!gated.releasePage.isCompleted) gated.releasePage.complete();
        snapshot.dispose();
        peer.dispose();
      }
    } finally {
      await db.close();
      await client.dispose();
    }
  });

  test(
      'native search ignores missing JSON1 and propagates indexed read failures',
      () async {
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final gated = _PageGateDatabase(raw)
      ..disableJson = true
      ..disableJsonEach = true;
    final db = MatrixSdkDatabase(inMemoryDatabasePath,
        database: gated, sqfliteFactory: databaseFactoryFfi);
    await db.open();
    final client = LocalClient(db);
    final room = client.room = Room(id: '!no-json1:local', client: client);
    try {
      await _store(db, client, room, 'e0', 1);
      final ids = await db.openSearchEventIds(room, maxBytes: 1);
      try {
        gated.failNextIndexedPage = true;
        await expectLater(ids.page(0, 1), throwsStateError);
        expect(ids.nextOffset, 0,
            reason:
                'failed I/O must not silently advance or report empty history');
        expect(await ids.page(0, 1), ['e0']);
        expect(ids.hasMore, isFalse);
        expect(gated.jsonCalls, 0,
            reason: 'native indexed reads have no JSON1 fallback dependency');
      } finally {
        ids.dispose();
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
        expect(budget.retainedBytes, 0,
            reason: 'native snapshots retain metadata, not a whole ID list');
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
      const filters = ChatSearchFilters(keyword: 'needle');
      var result = await search.search(filters);
      final matches = [...result.items];
      // A verified hit is returned before another disk page is read. Exhaust
      // the explicit continuation rather than treating the first slice as EOF.
      while (result.nextCursor != null) {
        result = await search.search(filters, cursor: result.nextCursor);
        matches.addAll(result.items);
      }
      expect(matches, hasLength(3));
      expect(matches.map((row) => row.eventId).toSet(),
          ids.where((id) => id != first).toSet());
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
