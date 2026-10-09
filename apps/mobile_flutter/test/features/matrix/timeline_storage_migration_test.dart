import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/features/matrix/timeline_migration_reader.dart';
import 'indexed_timeline_storage_test.dart' show StorageClient;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final size in [1000, 10000, 100000, 250000]) {
    test(
        'SQLCipher streaming migration $size keeps all IDs and bounded ACK pages',
        () async {
      final folder =
          await Directory.systemTemp.createTemp('indexed-migration-');
      final path = '${folder.path}/synthetic.db';
      const cipher = 'synthetic-test-only-timeline-key';
      final factory =
          createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
      final encryption =
          SQfLiteEncryptionHelper(factory: factory, path: path, cipher: cipher);
      final raw = await factory.openDatabase(path,
          options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey));
      var pages = 0, maxPage = 0, ticks = 0;
      final db = MatrixSdkDatabase('scale', database: raw,
          timelineMigrationReader: (key) async* {
        await for (final page in readEncryptedTimelineIds(
            path: path, cipher: cipher, fragment: key)) {
          pages++;
          if (page.length > maxPage) maxPage = page.length;
          yield page;
        }
      });
      await db.open();
      final room = Room(id: '!scale:synthetic', client: StorageClient(db));
      final source = jsonEncode(List.generate(
          size, (i) => 'opaque-${i.toString().padLeft(8, '0')}-雪-\\-"'));
      await raw
          .insert('box_timeline_fragments', {'k': '${room.id}|', 'v': source});
      final clock = Stopwatch()..start();
      final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
        ticks++;
      });
      try {
        await db.prepareTimelineStorage([room.id]);
        timer.cancel();
        clock.stop();
        expect(await db.getTimelineEventCount(room), size);
        expect(maxPage, lessThanOrEqualTo(256));
        expect(pages, (size / 256).ceil());
        expect(ticks, greaterThan(0));
        expect(
            (await raw.query('box_timeline_fragments', columns: ['v']))
                .single['v'],
            source);
        final lease = await db.openTimelineIdSnapshot(room,
            afterEventId: 'opaque-00000500-雪-\\-"',
            direction: TimelineIdDirection.newer);
        final page = await lease.next(limit: 30);
        expect(page.ids.first, 'opaque-00000499-雪-\\-"');
        expect(page.ids.last, 'opaque-00000470-雪-\\-"');
        expect(lease.length, size);
        lease.accept(page);
        lease.dispose();
        final plan = await raw.rawQuery(
            'EXPLAIN QUERY PLAN SELECT event_id FROM matrix_timeline_fragment_ids WHERE fragment_key=? AND epoch=? AND seq>? AND seq<=? ORDER BY seq LIMIT 30',
            ['${room.id}|', 1, 0, size]);
        expect(
            plan.any(
                (r) => r.values.any((v) => v.toString().contains('SEARCH'))),
            isTrue);
        // Only synthetic counts and timings are emitted, never IDs or bodies.
        debugPrint(
            'migration count=$size pages=$pages maxPage=$maxPage timerTicks=$ticks elapsedMs=${clock.elapsedMilliseconds}');
      } finally {
        timer.cancel();
        await db.close();
        await folder.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  }

  test(
      'migration failure resumes committed ordinal and does not own other room gate',
      () async {
    sqfliteFfiInit();
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    var fail = true;
    final entered = Completer<void>(), release = Completer<void>();
    final db = MatrixSdkDatabase('resume', database: raw,
        timelineMigrationReader: (key) async* {
      yield List.generate(256, (i) => 'id-$i');
      if (fail) {
        entered.complete();
        await release.future;
        throw StateError('synthetic worker failure');
      }
      yield ['tail'];
    });
    await db.open();
    final client = StorageClient(db);
    final room = Room(id: '!resume:synthetic', client: client);
    await raw.insert('box_timeline_fragments', {
      'k': '${room.id}|',
      'v': jsonEncode([...List.generate(256, (i) => 'id-$i'), 'tail'])
    });
    try {
      final preparing = db.prepareTimelineStorage([room.id]);
      final failure = expectLater(preparing, throwsStateError);
      await entered.future;
      final control = Room(id: '!small:synthetic', client: client);
      expect(
          await db
              .getTimelineEventCount(control)
              .timeout(const Duration(seconds: 2)),
          0);
      release.complete();
      await failure;
      expect(
          (await raw.query('matrix_timeline_fragment_state',
                  where: 'fragment_key=?', whereArgs: ['${room.id}|']))
              .single['migration_state'],
          'copying');
      fail = false;
      await db.prepareTimelineStorage([room.id]);
      expect(await db.getTimelineEventCount(room), 257);
      final lease =
          await db.openTimelineIdSnapshot(room, afterEventId: 'id-255');
      expect((await lease.next()).ids, ['tail']);
      lease.dispose();
    } finally {
      await db.close();
    }
  });
  test('same length legacy rewrite cannot publish mixed migrated order',
      () async {
    sqfliteFfiInit();
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    late Room room;
    final db = MatrixSdkDatabase('source-change', database: raw,
        timelineMigrationReader: (key) async* {
      yield ['a'];
      await raw.update('box_timeline_fragments', {'v': '["x","y"]'},
          where: 'k=?', whereArgs: [key]);
      yield ['b'];
    });
    await db.open();
    room = Room(id: '!changed:synthetic', client: StorageClient(db));
    await raw.insert(
        'box_timeline_fragments', {'k': '${room.id}|', 'v': '["a","b"]'});
    try {
      await expectLater(db.prepareTimelineStorage([room.id]), throwsStateError);
      final state = (await raw.query('matrix_timeline_fragment_state')).single;
      expect(state['migration_state'], 'copying');
      expect(
          (await raw.query('box_timeline_fragments')).single['v'], '["x","y"]');
    } finally {
      await db.close();
    }
  });

  test('closed client encrypted legacy projection restores old binary order',
      () async {
    final folder = await Directory.systemTemp.createTemp('legacy-projection-');
    final path = '${folder.path}/synthetic.db';
    const cipher = 'synthetic-test-only-projection-key';
    final factory =
        createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
    final encryption =
        SQfLiteEncryptionHelper(factory: factory, path: path, cipher: cipher);
    Future<Database> open() => factory.openDatabase(path,
        options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey));
    var raw = await open();
    var db = MatrixSdkDatabase('projection',
        database: raw,
        timelineMigrationReader: (key) => readEncryptedTimelineIds(
            path: path, cipher: cipher, fragment: key));
    await db.open();
    var client = StorageClient(db);
    var room = Room(id: '!projection:synthetic', client: client);
    try {
      await raw.insert(
          'box_timeline_fragments', {'k': '${room.id}|', 'v': '["old"]'});
      await db.prepareTimelineStorage([room.id]);
      await db.transaction(() => db.storeEventUpdate(
          EventUpdate(
              roomID: room.id,
              type: EventUpdateType.timeline,
              content: {
                'event_id': 'new',
                'type': 'm.room.encrypted',
                'sender': '@synthetic:local',
                'origin_server_ts': 1,
                'content': <String, dynamic>{}
              }),
          client));
      await expectLater(
          projectEncryptedTimelineForLegacyRollback(
              path: path, cipher: cipher, clientClosed: false),
          throwsStateError);
      await db.close();
      final result = await projectEncryptedTimelineForLegacyRollback(
          path: path, cipher: cipher, clientClosed: true);
      expect(result.events, 2);
      raw = await open();
      final legacy = (await raw.query('box_timeline_fragments',
              where: 'k=?', whereArgs: ['${room.id}|']))
          .single['v'] as String;
      expect(jsonDecode(legacy), ['new', 'old']);
      // Simulate a subsequent old binary append. New code must remigrate this
      // changed source, not mask it with the previously ready index.
      await raw.update('box_timeline_fragments', {'v': '["new","old","older"]'},
          where: 'k=?', whereArgs: ['${room.id}|']);
      db = MatrixSdkDatabase('projection',
          database: raw,
          timelineMigrationReader: (key) => readEncryptedTimelineIds(
              path: path, cipher: cipher, fragment: key));
      await db.open();
      client = StorageClient(db);
      room = Room(id: room.id, client: client);
      expect(await db.getEventIdList(room), ['new', 'old', 'older']);
      expect(await db.getEventById('new', room), isNotNull);
    } finally {
      await db.close();
      await folder.delete(recursive: true);
    }
  });

  test('failed staged rollback preserves source and index then retries',
      () async {
    final folder = await Directory.systemTemp.createTemp('staged-projection-');
    final path = '${folder.path}/synthetic.db';
    const cipher = 'synthetic-only-staged-projection';
    final factory =
        createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
    final encryption =
        SQfLiteEncryptionHelper(factory: factory, path: path, cipher: cipher);
    Future<Database> open() => factory.openDatabase(path,
        options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey));
    var raw = await open();
    final db = MatrixSdkDatabase('staged-projection',
        database: raw,
        timelineMigrationReader: (key) => readEncryptedTimelineIds(
            path: path, cipher: cipher, fragment: key));
    await db.open();
    final client = StorageClient(db);
    final room = Room(id: '!staged-projection:synthetic', client: client);
    final source = jsonEncode(List.generate(600, (i) => 'old-$i'));
    try {
      await raw
          .insert('box_timeline_fragments', {'k': '${room.id}|', 'v': source});
      await db.prepareTimelineStorage([room.id]);
      await db.transaction(() => db.storeEventUpdate(
          EventUpdate(
              roomID: room.id,
              type: EventUpdateType.timeline,
              content: {
                'event_id': 'head',
                'type': 'm.room.encrypted',
                'sender': '@synthetic:local',
                'origin_server_ts': 1,
                'content': <String, dynamic>{}
              }),
          client));
      final before = (await raw.query('matrix_timeline_fragment_state',
              where: 'fragment_key=?', whereArgs: ['${room.id}|']))
          .single;
      await raw.execute(
          'CREATE TABLE IF NOT EXISTS matrix_timeline_rollback_stage '
          '(fragment_key TEXT PRIMARY KEY,v BLOB NOT NULL,items_written INTEGER NOT NULL)');
      await raw.execute(
          "CREATE TRIGGER synthetic_projection_failure BEFORE UPDATE OF items_written "
          "ON matrix_timeline_rollback_stage WHEN NEW.items_written>=256 "
          "BEGIN SELECT RAISE(ABORT,'synthetic staging failure'); END");
      await db.close();
      await expectLater(
          projectEncryptedTimelineForLegacyRollback(
              path: path, cipher: cipher, clientClosed: true),
          throwsStateError);
      raw = await open();
      expect(
          (await raw.query('box_timeline_fragments',
                  where: 'k=?', whereArgs: ['${room.id}|']))
              .single['v'],
          source);
      expect(
          (await raw.query('matrix_timeline_fragment_state',
                  where: 'fragment_key=?', whereArgs: ['${room.id}|']))
              .single,
          before);
      expect(
          (await raw.query('box_events',
                  where: 'k=?', whereArgs: ['${room.id}|head']))
              .length,
          1);
      await raw.execute('DROP TRIGGER synthetic_projection_failure');
      await raw.close();
      final result = await projectEncryptedTimelineForLegacyRollback(
          path: path, cipher: cipher, clientClosed: true);
      expect(result.events, 601);
      raw = await open();
      final projected = jsonDecode((await raw.query('box_timeline_fragments',
              where: 'k=?', whereArgs: ['${room.id}|']))
          .single['v'] as String) as List;
      expect(projected.length, 601);
      expect(projected.first, 'head');
      expect(projected.last, 'old-599');
      await raw.close();
    } finally {
      await db.close();
      await folder.delete(recursive: true);
    }
  });
  test('account close cancels encrypted migration and reopened account resumes',
      () async {
    final folder = await Directory.systemTemp.createTemp('close-migration-');
    final path = '${folder.path}/synthetic.db';
    const cipher = 'synthetic-test-only-close-key';
    final factory =
        createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
    final encryption =
        SQfLiteEncryptionHelper(factory: factory, path: path, cipher: cipher);
    Future<Database> open() => factory.openDatabase(path,
        options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey));
    var raw = await open();
    var pages = 0;
    final entered = Completer<void>();
    var db = MatrixSdkDatabase('close', database: raw,
        timelineMigrationReader: (key) async* {
      await for (final page in readEncryptedTimelineIds(
          path: path, cipher: cipher, fragment: key)) {
        if (++pages == 2) entered.complete();
        yield page;
      }
    });
    await db.open();
    var room = Room(id: '!close:synthetic', client: StorageClient(db));
    await raw.insert('box_timeline_fragments', {
      'k': '${room.id}|',
      'v': jsonEncode(List.generate(5000, (i) => 'id-$i'))
    });
    try {
      final pending = db.prepareTimelineStorage([room.id]);
      final failure =
          expectLater(pending, throwsA(isA<TimelineStorageClosed>()));
      await entered.future;
      await db.close().timeout(const Duration(seconds: 2));
      await failure;
      raw = await open();
      final state = (await raw.query('matrix_timeline_fragment_state',
              where: 'fragment_key=?', whereArgs: ['${room.id}|']))
          .single;
      expect(state['migration_state'], 'copying');
      expect(state['migration_next'], greaterThanOrEqualTo(256));
      db = MatrixSdkDatabase('close',
          database: raw,
          timelineMigrationReader: (key) => readEncryptedTimelineIds(
              path: path, cipher: cipher, fragment: key));
      await db.open();
      room = Room(id: room.id, client: StorageClient(db));
      expect(await db.getTimelineEventCount(room), 5000);
      final lease = await db.openTimelineIdSnapshot(room);
      await db.close();
      await expectLater(lease.next(), throwsA(isA<TimelineStorageClosed>()));
    } finally {
      await db.close();
      await folder.delete(recursive: true);
    }
  });
  for (final size in [1000, 100000]) {
    test('encrypted retained search backfill $size is bounded and reopens',
        () async {
      final folder = await Directory.systemTemp.createTemp('retained-search-');
      final path = '${folder.path}/synthetic.db';
      const cipher = 'synthetic-only-retained-search';
      final factory =
          createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
      final encryption =
          SQfLiteEncryptionHelper(factory: factory, path: path, cipher: cipher);
      Future<Database> open() => factory.openDatabase(path,
          options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey));
      var raw = await open();
      var pages = 0, maxPage = 0, ticks = 0;
      var db = MatrixSdkDatabase('retained-backfill', database: raw,
          timelineSearchMigrationReader: (room, after) async* {
        await for (final page in readEncryptedRetainedSearch(
            path: path, cipher: cipher, roomId: room, afterEventId: after)) {
          pages++;
          maxPage = page.length > maxPage ? page.length : maxPage;
          yield page;
        }
      });
      await db.open();
      var room =
          Room(id: '!retained-backfill:synthetic', client: StorageClient(db));
      for (var start = 0; start < size; start += 256) {
        final batch = raw.batch();
        for (var i = start; i < size && i < start + 256; i++) {
          batch.insert('box_events', {
            'k': '${room.id}|event-${i.toString().padLeft(8, '0')}',
            'v': jsonEncode({
              'event_id': 'event-${i.toString().padLeft(8, '0')}',
              'origin_server_ts': i,
              'type': 'm.room.encrypted',
              'content': <String, dynamic>{}
            })
          });
        }
        await batch.commit(noResult: true);
      }
      final clock = Stopwatch()..start();
      final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
        ticks++;
      });
      try {
        final search = await db.openSearchEventIds(room);
        timer.cancel();
        clock.stop();
        var count = 0;
        while (search.hasMore) {
          final ids = await search.page(search.nextOffset, 256);
          expect(search.lastRawCount, lessThanOrEqualTo(256));
          for (final id in ids) {
            expect(
                id, 'event-${(size - 1 - count++).toString().padLeft(8, '0')}');
          }
        }
        expect(count, size);
        search.dispose();
        expect(maxPage, lessThanOrEqualTo(256));
        expect(pages, (size / 256).ceil());
        expect(ticks, greaterThan(0));
        final plan = await raw.rawQuery(
            'EXPLAIN QUERY PLAN SELECT * FROM matrix_retained_search_rows '
            'WHERE room_id=? AND (bucket,sort_ts,event_id,row_id)>(?,?,?,?) '
            'ORDER BY bucket,sort_ts,event_id,row_id LIMIT 256',
            [room.id, 0, -size, '', 0]);
        expect(
            plan.any((r) => r.values.any(
                (v) => v.toString().contains('matrix_retained_search_order'))),
            isTrue);
        expect(await db.getEventIdList(room), isEmpty);
        debugPrint(
            'retainedSearch count=$size pages=$pages maxPage=$maxPage ticks=$ticks elapsedMs=${clock.elapsedMilliseconds}');
        await db.close();
        raw = await open();
        db = MatrixSdkDatabase('retained-backfill',
            database: raw,
            timelineSearchMigrationReader: (room, after) =>
                throw StateError('Ready index must not backfill again'));
        await db.open();
        room = Room(id: room.id, client: StorageClient(db));
        final reopened = await db.openSearchEventIds(room);
        expect((await reopened.page(0, 1)).single,
            'event-${(size - 1).toString().padLeft(8, '0')}');
        reopened.dispose();
      } finally {
        timer.cancel();
        await db.close();
        await folder.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
  test(
      'encrypted retained backfill resumes and stale pages respect concurrent delete',
      () async {
    final folder = await Directory.systemTemp.createTemp('retained-resume-');
    final path = '${folder.path}/synthetic.db';
    const cipher = 'synthetic-only-retained-resume';
    final factory =
        createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
    final encryption =
        SQfLiteEncryptionHelper(factory: factory, path: path, cipher: cipher);
    Future<Database> open() => factory.openDatabase(path,
        options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey));
    var raw = await open();
    var pages = 0;
    final entered = Completer<void>(), release = Completer<void>();
    var db = MatrixSdkDatabase('retained-resume', database: raw,
        timelineSearchMigrationReader: (room, after) async* {
      await for (final page in readEncryptedRetainedSearch(
          path: path, cipher: cipher, roomId: room, afterEventId: after)) {
        if (++pages == 2) {
          entered.complete();
          await release.future;
          yield page;
          throw StateError('Synthetic worker retry');
        }
        yield page;
      }
    });
    await db.open();
    var client = StorageClient(db),
        room =
            Room(id: '!retained-resume:synthetic', client: StorageClient(db));
    final batch = raw.batch();
    for (var i = 0; i < 600; i++) {
      final id = 'event-${i.toString().padLeft(4, '0')}';
      batch.insert('box_events', {
        'k': '${room.id}|$id',
        'v': jsonEncode({
          'event_id': id,
          'origin_server_ts': i,
          'type': 'm.room.encrypted',
          'content': <String, dynamic>{}
        })
      });
    }
    await batch.commit(noResult: true);
    try {
      final pending = db.openSearchEventIds(room);
      final failure = expectLater(pending, throwsStateError);
      await entered.future;
      // Worker has already read event0256 in its pending page. Its SQLite read
      // statement is closed while waiting; a real same-file write must proceed.
      await db
          .removeEvent('event-0256', room.id)
          .timeout(const Duration(seconds: 2));
      await db.storeEventUpdate(
          EventUpdate(
              roomID: room.id,
              type: EventUpdateType.timeline,
              content: {
                'event_id': 'fresh',
                'origin_server_ts': 1000,
                'type': 'm.room.encrypted',
                'content': <String, dynamic>{}
              }),
          client);
      release.complete();
      await failure;
      expect(
          (await raw.query('matrix_retained_search_state',
                  where: 'room_id=?', whereArgs: [room.id]))
              .single['ready'],
          0);
      await db.close();
      raw = await open();
      String? resumedAfter;
      db = MatrixSdkDatabase('retained-resume', database: raw,
          timelineSearchMigrationReader: (room, after) {
        resumedAfter = after;
        return readEncryptedRetainedSearch(
            path: path, cipher: cipher, roomId: room, afterEventId: after);
      });
      await db.open();
      client = StorageClient(db);
      room = Room(id: room.id, client: client);
      final search = await db.openSearchEventIds(room);
      expect(resumedAfter, 'event-0511');
      final ids = <String>[];
      while (search.hasMore) {
        ids.addAll(await search.page(search.nextOffset, 256));
      }
      expect(ids.length, 600);
      expect(ids.first, 'fresh');
      expect(ids, isNot(contains('event-0256')));
      search.dispose();
    } finally {
      if (!release.isCompleted) release.complete();
      await db.close();
      await folder.delete(recursive: true);
    }
  });
}
