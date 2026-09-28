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
      final frozen = await lease.openLocalSearchIds(room.id);
      try {
        expect(await frozen.page(0, 2), ids.take(2).toList());
        final keyed =
            await lease.readLocalSearchByIds(room.id, ids.take(2).toList());
        expect(keyed.map((e) => e.eventId), ids.take(2));
        expect(keyed.first.isDisplayable, isFalse);
      } finally {
        frozen.dispose();
      }
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
