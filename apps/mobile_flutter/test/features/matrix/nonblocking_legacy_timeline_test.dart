import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/features/matrix/timeline_migration_reader.dart';
import 'fixtures/delegating_sqlite_database.dart';

class _Client extends Client {
  _Client(this.store,
      {Map<String, int>? batchSizes,
      http.Response Function(http.Request)? respond})
      : super('nonblocking',
            databaseBuilder: (_) async => store,
            httpClient: MockClient((r) async {
              if (respond != null) return respond(r);
              final body = r.url.path.endsWith('/filter')
                  ? {'filter_id': 'fixture'}
                  : {
                      'next_batch': 'fixture-next',
                      'rooms': {
                        'join': batchSizes != null
                            ? {
                                for (final entry in batchSizes.entries)
                                  entry.key: {
                                    'timeline': {
                                      'limited': false,
                                      'events': List.generate(entry.value,
                                          (i) => _message('fresh-$i'))
                                    }
                                  }
                              }
                            : {
                                '!legacy:synthetic': {
                                  'timeline': {
                                    'limited': false,
                                    'events': [_message('fresh')]
                                  },
                                },
                                '!small:synthetic': {
                                  'timeline': {
                                    'limited': false,
                                    'events': [_message('small')]
                                  },
                                }
                              }
                      },
                      'device_one_time_keys_count': <String, Object>{},
                    };
              return http.Response(jsonEncode(body), 200,
                  headers: {'content-type': 'application/json'});
            })) {
    homeserver = Uri.parse('https://synthetic.test');
    accessToken = 'synthetic-fixture';
    backgroundSync = false;
  }
  final MatrixSdkDatabase store;
  @override
  String get userID => '@self:synthetic';
  @override
  DatabaseApi get database => store;
}

Map<String, dynamic> _message(String id) => {
      'event_id': id,
      'type': 'm.room.message',
      'sender': '@other:synthetic',
      'origin_server_ts': 1,
      'content': {'msgtype': 'm.text', 'body': 'fixture'},
    };

class _SlowMigrationSql extends DelegatingSqliteDatabase {
  _SlowMigrationSql(super.delegate);
  final chunks = <int>[];
  @override
  Batch batch() => _SlowMigrationBatch(delegate.batch(), chunks);
}

class _SlowMigrationBatch extends Fake implements Batch {
  _SlowMigrationBatch(this.delegate, this.chunks);
  final Batch delegate;
  final List<int> chunks;
  int rows = 0;
  @override
  void insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      delegate.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);
  @override
  void execute(String sql, [List<Object?>? args]) =>
      delegate.execute(sql, args);
  @override
  void rawInsert(String sql, [List<Object?>? args]) {
    if (sql.startsWith('INSERT OR IGNORE INTO matrix_timeline_fragment_ids ')) {
      rows++;
    }
    delegate.rawInsert(sql, args);
  }

  @override
  void rawUpdate(String sql, [List<Object?>? args]) =>
      delegate.rawUpdate(sql, args);
  @override
  void update(String table, Map<String, Object?> values,
          {String? where,
          List<Object?>? whereArgs,
          ConflictAlgorithm? conflictAlgorithm}) =>
      delegate.update(table, values,
          where: where,
          whereArgs: whereArgs,
          conflictAlgorithm: conflictAlgorithm);
  @override
  Future<List<Object?>> commit(
      {bool? exclusive, bool? noResult, bool? continueOnError}) async {
    if (rows > 0) {
      chunks.add(rows);
      await Future<void>.delayed(const Duration(milliseconds: 9));
    }
    return delegate.commit(
        exclusive: exclusive,
        noResult: noResult,
        continueOnError: continueOnError);
  }
}

// Native integration places synthetic encrypted fixtures under Android private
// cache storage. Host tests retain their approved verification artifact root.
Directory? nativeLegacyArtifactRoot;
Directory get _legacyArtifactRoot =>
    nativeLegacyArtifactRoot ??
    Directory(
        '../../docs/verification/artifacts/2026-10-09/mobile-responsive-maintenance/history');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(SQfLiteEncryptionHelper.ffiInit);
  for (final sync in [true, false]) {
    test(
        sync
            ? 'nonlimited real sync progresses with held legacy migration'
            : 'room snapshot and writes progress with held legacy migration',
        () async {
      final raw = await createDatabaseFactoryFfi(
              ffiInit: SQfLiteEncryptionHelper.ffiInit)
          .openDatabase(inMemoryDatabasePath);
      final entered = Completer<void>(), release = Completer<void>();
      final db = MatrixSdkDatabase('nonblocking', database: raw,
          timelineMigrationReader: (key) async* {
        entered.complete();
        await release.future;
        yield ['old', 'tail'];
      });
      await db.open();
      await raw.insert('box_timeline_fragments', {
        'k': '!legacy:synthetic|',
        'v': '["old","tail"]',
      });
      final client = _Client(db);
      final room = Room(id: '!legacy:synthetic', client: client);
      final maintenance = db.prepareTimelineStorage([room.id]);
      Future<void>? operation;
      try {
        await entered.future;
        if (sync) {
          operation = client.oneShotSync();
          await operation.timeout(const Duration(milliseconds: 700));
          expect(await db.getEventIdList(room, limit: 40),
              ['fresh', 'old', 'tail']);
          expect(
              await db.getEventIdList(client.getRoomById('!small:synthetic')!),
              ['small']);
        } else {
          final snapshot = await db
              .openTimelineIdSnapshot(room)
              .timeout(const Duration(milliseconds: 700));
          expect(snapshot.exactLength, isNull);
          expect((await snapshot.next()).ids, ['old', 'tail']);
          await db.getTimelineEventPositions(room, ['fresh', 'old']);
          operation = db.transaction(() async {
            await db.storeEventUpdate(
                EventUpdate(
                    roomID: room.id,
                    type: EventUpdateType.timeline,
                    content: _message('fresh')),
                client);
            await db.removeEvent('old', room.id);
          });
          await operation.timeout(const Duration(milliseconds: 700));
          expect(await db.getEventIdList(room), ['fresh', 'tail']);
          expect((await snapshot.next()).ids, ['old', 'tail'],
              reason:
                  'unaccepted page and old snapshot preserve their revision');
          snapshot.dispose();
        }
      } finally {
        release.complete();
        await maintenance;
        await operation;
        expect(await db.getEventIdList(room),
            sync ? ['fresh', 'old', 'tail'] : ['fresh', 'tail']);
        await client.dispose();
        await db.close();
      }
    });
  }

  for (final sizes in [
    <String, int>{'!legacy:synthetic': 1000},
    <String, int>{'!legacy:synthetic': 300, '!small:synthetic': 300}
  ]) {
    test(
        'nonlimited sync preserves preflight authority for batch ${sizes.values.join('+')}',
        () async {
      final raw = await createDatabaseFactoryFfi(
              ffiInit: SQfLiteEncryptionHelper.ffiInit)
          .openDatabase(inMemoryDatabasePath);
      final release = Completer<void>();
      final db = MatrixSdkDatabase('large-sync', database: raw,
          timelineMigrationReader: (key) async* {
        await release.future;
        yield ['old'];
      });
      await db.open();
      final client = _Client(db, batchSizes: sizes);
      try {
        for (final key in sizes.keys) {
          await raw
              .insert('box_timeline_fragments', {'k': '$key|', 'v': '["old"]'});
        }
        await client.oneShotSync().timeout(const Duration(seconds: 10));
        for (final entry in sizes.entries) {
          final room = client.getRoomById(entry.key)!;
          expect(await db.getEventIdList(room, limit: 2),
              ['fresh-${entry.value - 1}', 'fresh-${entry.value - 2}']);
        }
      } finally {
        release.complete();
        await db.close();
        await client.dispose();
      }
    });
  }

  test('maintenance lease waits outside gate and cancellation releases owner',
      () async {
    final raw =
        await createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit)
            .openDatabase(inMemoryDatabasePath);
    final waiting = Completer<void>(), allow = Completer<void>();
    var reads = 0, acquired = 0, released = 0;
    final db = MatrixSdkDatabase('lease', database: raw,
        timelineMaintenanceLease: (cancelled) async {
      if (!waiting.isCompleted) waiting.complete();
      await Future.any([allow.future, cancelled]);
      acquired++;
      return () {
        released++;
      };
    }, timelineMigrationReader: (key) async* {
      reads++;
      yield ['old'];
    });
    await db.open();
    final client = _Client(db),
        room = Room(id: '!lease:synthetic', client: _Client(db));
    await raw
        .insert('box_timeline_fragments', {'k': '${room.id}|', 'v': '["old"]'});
    final task = db.prepareTimelineStorage([room.id]);
    final rejected = expectLater(task, throwsA(isA<TimelineStorageClosed>()));
    await waiting.future;
    expect(reads, 0, reason: 'source worker does not start before heavy lease');
    final snapshot = await db
        .openTimelineIdSnapshot(room)
        .timeout(const Duration(milliseconds: 500));
    expect((await snapshot.next()).ids, ['old']);
    snapshot.dispose();
    await db.close().timeout(const Duration(seconds: 2));
    await rejected;
    expect(acquired, released,
        reason: 'close after acquire still releases lease');
    expect(reads, 0);
    await client.dispose();
  });

  test(
      'another legacy room actual page progresses during held exact membership',
      () async {
    final raw =
        await createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit)
            .openDatabase(inMemoryDatabasePath);
    final entered = Completer<void>(), release = Completer<void>();
    final db = MatrixSdkDatabase('page-priority', database: raw,
        timelineMigrationReader: (key) async* {
      await release.future;
      yield ['old'];
    }, timelineLegacyPageReader: (key, source,
            {int start = 0,
            int limit = 256,
            List<String>? findEventIds,
            bool reverse = false,
            bool Function()? isCancelled}) async {
      if (findEventIds != null) {
        entered.complete();
        await release.future;
        return TimelineLegacyPage([], start: 0, hasMore: false);
      }
      return TimelineLegacyPage(['old'], start: 0, hasMore: false);
    });
    await db.open();
    final client = _Client(db);
    for (final room in ['big', 'other']) {
      await raw.insert(
          'box_timeline_fragments', {'k': '!$room:synthetic|', 'v': '["old"]'});
    }
    final query = db.getTimelineEventPositions(
        Room(id: '!big:synthetic', client: client), ['unknown']);
    try {
      await entered.future;
      final snapshot = await db
          .openTimelineIdSnapshot(Room(id: '!other:synthetic', client: client));
      final clock = Stopwatch()..start();
      expect(
          (await snapshot.next().timeout(const Duration(milliseconds: 500)))
              .ids,
          ['old']);
      final anchored = await snapshot.fork(afterEventId: 'old');
      anchored.dispose();
      snapshot.dispose();
      expect(release.isCompleted, isFalse);
      debugPrint(
          'heldMembershipOtherLegacyPage elapsedMs=${clock.elapsedMilliseconds}');
    } finally {
      release.complete();
      await query;
      await db.close();
      await client.dispose();
    }
  });
  test(
      'maintenance over budget shrinks next transaction through minimum one ID',
      () async {
    final raw =
        await createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit)
            .openDatabase(inMemoryDatabasePath);
    final observed = _SlowMigrationSql(raw);
    final ids = List.generate(512, (i) => 'old-$i');
    final db = MatrixSdkDatabase('adaptive', database: observed,
        timelineMigrationReader: (key) async* {
      for (var offset = 0; offset < ids.length; offset += 256) {
        yield ids.sublist(offset, offset + 256);
      }
    });
    await db.open();
    await raw.insert('box_timeline_fragments',
        {'k': '!adaptive:synthetic|', 'v': jsonEncode(ids)});
    try {
      await db.prepareTimelineStorage(['!adaptive:synthetic']);
      expect(observed.chunks.first, 256);
      expect(observed.chunks[1], lessThan(256),
          reason: 'measured >4ms must reduce the next commit');
      expect(observed.chunks.every((n) => n >= 1 && n <= 256), isTrue);
      expect(observed.chunks.reduce((a, b) => a + b), 512);
      expect(observed.chunks, contains(1),
          reason: 'slow IO eventually reaches bounded minimum, never zero');
      expect(db.timelineMaintenanceMetrics['overBudget'], greaterThan(0));
      expect(db.timelineMaintenanceMetrics['minimumRows'], 1);
      debugPrint(
          'adaptiveMigration firstChunks=${observed.chunks.take(8).toList()} totalChunks=${observed.chunks.length} metrics=${db.timelineMaintenanceMetrics}');
    } finally {
      await db.close();
    }
  });

  test(
      'public requestHistory commits chunk while old canonical migration is held',
      () async {
    final raw =
        await createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit)
            .openDatabase(inMemoryDatabasePath);
    final entered = Completer<void>(), release = Completer<void>();
    final db = MatrixSdkDatabase('history-entry', database: raw,
        timelineMigrationReader: (key) async* {
      entered.complete();
      await release.future;
      yield ['old'];
    });
    await db.open();
    final client = _Client(db,
        respond: (request) => http.Response(
            jsonEncode(request.url.path.contains('/send/')
                ? {'event_id': 'sent'}
                : request.url.path.contains('/state/m.room.member')
                    ? {'membership': 'join', 'displayname': 'Fixture'}
                    : {
                        'chunk': [_message('history')],
                        'start': 'before',
                        'end': 'after',
                        'state': []
                      }),
            200,
            headers: {'content-type': 'application/json'}));
    final room =
        Room(id: '!history:synthetic', client: client, prev_batch: 'before');
    client.rooms.add(room);
    await raw
        .insert('box_timeline_fragments', {'k': '${room.id}|', 'v': '["old"]'});
    final maintenance = db.prepareTimelineStorage([room.id]);
    Future<int>? request;
    try {
      await entered.future;
      request = room.requestHistory(historyCount: 1);
      expect(await request.timeout(const Duration(milliseconds: 700)), 1);
      expect(release.isCompleted, isFalse);
      expect(await db.getEventIdList(room), ['old', 'history']);
      final event = await client
          .getEventByPushNotification(
              PushNotification(
                  devices: const [],
                  eventId: 'fetched',
                  roomId: room.id,
                  content: {'msgtype': 'm.text', 'body': 'fixture'},
                  sender: '@other:synthetic',
                  type: EventTypes.Message),
              returnNullIfSeen: false)
          .timeout(const Duration(milliseconds: 700));
      expect(event?.eventId, 'fetched');
      expect(release.isCompleted, isFalse);
      expect(await db.getEventIdList(room), ['fetched', 'old', 'history']);
      expect(
          await room.sendEvent({'msgtype': 'm.text', 'body': 'fixture'},
              txid:
                  'fixture-local-txn').timeout(
              const Duration(milliseconds: 700)),
          'sent');
      expect(release.isCompleted, isFalse);
      expect(await db.getEventIdList(room, includeSending: true),
          contains('sent'));
      expect((await db.getEventById('sent', room))?.status, EventStatus.sent);
    } finally {
      release.complete();
      await maintenance;
      await request;
      await db.close();
      await client.dispose();
    }
  });
  test(
      'close cancels exact lookup inside generic transaction without replaying callback',
      () async {
    final raw =
        await createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit)
            .openDatabase(inMemoryDatabasePath);
    final entered = Completer<void>();
    var callbacks = 0;
    final db = MatrixSdkDatabase('transaction-close', database: raw,
        timelineMigrationReader: (key) async* {
      yield ['old'];
      throw StateError('stop at immutablebase');
    }, timelineLegacyPageReader: (key, source,
            {int start = 0,
            int limit = 256,
            List<String>? findEventIds,
            bool reverse = false,
            bool Function()? isCancelled}) async {
      entered.complete();
      while (isCancelled?.call() != true) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      throw TimelineStorageClosed();
    });
    await db.open();
    final client = _Client(db);
    const key = '!legacy:synthetic|';
    await raw.insert('box_timeline_fragments', {'k': key, 'v': '["old"]'});
    final operation = db.transaction(() async {
      callbacks++;
      await db.storeEventUpdate(
          EventUpdate(
              roomID: '!legacy:synthetic',
              type: EventUpdateType.timeline,
              content: _message('unknown')),
          client);
    });
    final rejected =
        expectLater(operation, throwsA(isA<TimelineStorageClosed>()));
    await entered.future.timeout(const Duration(seconds: 2));
    final search =
        db.openSearchEventIds(Room(id: '!legacy:synthetic', client: client));
    final searchRejected =
        expectLater(search, throwsA(isA<TimelineStorageClosed>()));
    await Future<void>.delayed(Duration.zero);
    await db.close().timeout(const Duration(seconds: 2));
    await searchRejected;
    await rejected;
    expect(callbacks, 1);
    await client.dispose();
  });
  for (final count in [250000, 1000000]) {
    test('foreground transition at $count legacy IDs while worker is held',
        () async {
      final raw = await createDatabaseFactoryFfi(
              ffiInit: SQfLiteEncryptionHelper.ffiInit)
          .openDatabase(inMemoryDatabasePath);
      final release = Completer<void>();
      final db = MatrixSdkDatabase('scale', database: raw,
          timelineMigrationReader: (key) async* {
        await release.future;
        // The real worker is separately scale tested. Holding it proves that
        // foreground queries do not accidentally join its completion barrier.
        for (var start = 0; start < count; start += 256) {
          yield List.generate(
              (count - start).clamp(0, 256), (i) => 'old-${start + i}');
        }
      });
      await db.open();
      final client = _Client(db),
          room = Room(id: '!legacy:synthetic', client: _Client(db));
      await raw.insert('box_timeline_fragments', {
        'k': '${room.id}|',
        'v': jsonEncode(List.generate(count, (i) => 'old-$i'))
      });
      final before = ProcessInfo.currentRss, clock = Stopwatch()..start();
      var peak = before;
      final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
        if (ProcessInfo.currentRss > peak) peak = ProcessInfo.currentRss;
      });
      try {
        final snapshot = await db
            .openTimelineIdSnapshot(room)
            .timeout(const Duration(seconds: 5));
        final page = await snapshot.next(limit: 40);
        expect(page.ids, List.generate(40, (i) => 'old-$i'));
        expect(page.rawCount, lessThanOrEqualTo(40));
        snapshot.dispose();
        final readMs = clock.elapsedMilliseconds;
        await db
            .storeEventUpdate(
                EventUpdate(
                    roomID: room.id,
                    type: EventUpdateType.timeline,
                    content: _message('fresh')),
                client)
            .timeout(const Duration(seconds: 5));
        expect(await db.getEventIdList(room, limit: 3),
            ['fresh', 'old-0', 'old-1']);
        clock.stop();
        debugPrint(
            'transition count=$count readMs=$readMs totalMs=${clock.elapsedMilliseconds} rssBefore=$before rssPeak=$peak');
      } finally {
        timer.cancel();
        release.complete();
        // Close cancels after the first received batch, avoiding an unnecessary
        // full copy in the foreground-progress measurement.
        await db.close();
        await client.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
  for (final count in [250000, 1000000]) {
    test('native bounded blob authority and persisted membership at $count',
        () async {
      final root = _legacyArtifactRoot;
      await root.create(recursive: true);
      final folder = await root.createTemp('native-');
      final path = '${folder.absolute.path}/synthetic.db';
      const cipher = 'synthetic-native-page-only';
      final factory =
          createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
      final encryption =
          SQfLiteEncryptionHelper(factory: factory, path: path, cipher: cipher);
      final raw = await factory.openDatabase(path,
          options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey));
      final entered = Completer<void>(), release = Completer<void>();
      final db = MatrixSdkDatabase('native-progress',
          database: raw,
          timelineMigrationReader: (key) async* {
            entered.complete();
            await release.future;
            yield ['old-0'];
          },
          timelineLegacyPageReader: (key, source,
                  {int start = 0,
                  int limit = 256,
                  List<String>? findEventIds,
                  bool reverse = false,
                  bool Function()? isCancelled}) =>
              readEncryptedTimelinePage(
                  path: path,
                  cipher: cipher,
                  fragment: key,
                  sourceIdentity: source,
                  start: start,
                  limit: limit,
                  findEventIds: findEventIds,
                  reverse: reverse,
                  isCancelled: isCancelled));
      await db.open();
      final client = _Client(db),
          room = Room(id: '!legacy:synthetic', client: _Client(db));
      await raw.insert('box_timeline_fragments', {
        'k': '${room.id}|',
        'v': jsonEncode(List.generate(count, (i) => 'old-$i'))
      });
      await db
          .openTimelineIdSnapshot(room)
          .then((snapshot) => snapshot.dispose());
      await entered.future;
      final before = ProcessInfo.currentRss, clock = Stopwatch()..start();
      var peak = before, ticks = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
        ticks++;
        if (ProcessInfo.currentRss > peak) peak = ProcessInfo.currentRss;
      });
      try {
        final snapshot = await db.openTimelineIdSnapshot(room);
        expect(snapshot.exactLength, isNull);
        final page = await snapshot.next(limit: 40);
        expect(page.ids, List.generate(40, (i) => 'old-$i'));
        snapshot.dispose();
        final firstPageMs = clock.elapsedMilliseconds;
        debugPrint(
            'native modes locking=${await raw.rawQuery("PRAGMA locking_mode")} journal=${await raw.rawQuery("PRAGMA journal_mode")}');
        final repeat = await db.openTimelineIdSnapshot(room);
        expect((await repeat.next(limit: 3)).ids, ['old-0', 'old-1', 'old-2']);
        repeat.dispose();
        await raw.insert('box_timeline_fragments', {
          'k': '!control:synthetic|',
          'v': jsonEncode(['control-0', 'control-1', 'control-2'])
        });
        final firstWrite = db.storeEventUpdate(
            EventUpdate(
                roomID: room.id,
                type: EventUpdateType.timeline,
                content: _message('fresh')),
            client);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final control = Stopwatch()..start();
        final controlSnapshot = await db
            .openTimelineIdSnapshot(
                Room(id: '!control:synthetic', client: client))
            .timeout(const Duration(milliseconds: 500));
        expect(
            (await controlSnapshot
                    .next(limit: 3)
                    .timeout(const Duration(milliseconds: 1500)))
                .ids,
            ['control-0', 'control-1', 'control-2']);
        controlSnapshot.dispose();
        control.stop();
        await firstWrite;
        final firstWriteMs = clock.elapsedMilliseconds - firstPageMs;
        final cache = await factory.openDatabase('$path.timeline_pages.sqlite',
            options:
                OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey));
        expect(
            (await cache.query('matrix_timeline_legacy_bloom_state'))
                .single['item_count'],
            count);
        await cache.close();
        clock.reset();
        await db.storeEventUpdate(
            EventUpdate(
                roomID: room.id,
                type: EventUpdateType.timeline,
                content: _message('second-fresh')),
            client);
        final secondWriteMs = clock.elapsedMilliseconds;
        expect(await db.getEventIdList(room, limit: 3),
            ['second-fresh', 'fresh', 'old-0']);
        final anchored = await db.openTimelineIdSnapshot(room,
            afterEventId: 'old-${count - 10}');
        final tailPage = await anchored.next(limit: 5);
        expect(tailPage.ids, List.generate(5, (i) => 'old-${count - 9 + i}'));
        anchored.dispose();
        expect(ticks, greaterThan(0));
        debugPrint(
            'nativeTransition count=$count firstPageMs=$firstPageMs firstWriteMs=$firstWriteMs secondWriteMs=$secondWriteMs controlMs=${control.elapsedMilliseconds} ticks=$ticks rssBefore=$before rssPeak=$peak');
        if (count == 250000) {
          final legacyJson = jsonEncode(List.generate(count, (i) => 'old-$i'));
          for (var i = 0; i < 100; i++) {
            final restored = Room(id: '!preview-$i:synthetic', client: client);
            if (i < 10) {
              restored.lastEvent = Event.fromJson(_message('old-0'), restored);
              await raw.insert('box_timeline_fragments',
                  {'k': '${restored.id}|', 'v': legacyJson});
              await raw.insert('box_events', {
                'k': '${restored.id}|old-0',
                'v': jsonEncode(_message('old-0'))
              });
            }
            await raw.insert('box_rooms',
                {'k': restored.id, 'v': jsonEncode(restored.toJson())});
          }
          final restoredClock = Stopwatch()..start();
          final restoredRooms = await db.getRoomList(client);
          expect(restoredRooms.length, 100);
          expect(
              restoredRooms
                  .where((room) => room.lastEvent?.eventId == 'old-0')
                  .length,
              10);
          debugPrint(
              'cachedRoomRestore rooms=100 legacyRooms=10 legacyIdsPerRoom=250000 elapsedMs=${restoredClock.elapsedMilliseconds}');
        }
      } finally {
        timer.cancel();
        release.complete();
        await db.close();
        await client.dispose();
        await folder.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
  test(
      'encrypted accelerator invalidates same-size legacy rewrite and missing part',
      () async {
    final root = _legacyArtifactRoot;
    await root.create(recursive: true);
    final folder = await root.createTemp('identity-');
    final path = '${folder.absolute.path}/synthetic.db';
    const cipher = 'synthetic-cache-identity-only';
    final factory =
        createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
    final encryption =
        SQfLiteEncryptionHelper(factory: factory, path: path, cipher: cipher);
    final raw = await factory.openDatabase(path,
        options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey));
    final db = MatrixSdkDatabase('identity', database: raw);
    await db.open();
    const key = '!identity:synthetic|';
    Future<String> identity() async {
      final rows = await raw.rawQuery(
          'SELECT f.rowid AS r,COALESCE(v.revision,0) AS n FROM box_timeline_fragments f LEFT JOIN matrix_timeline_legacy_revision v ON v.fragment_key=f.k WHERE f.k=?',
          [key]);
      return '${rows.single['r']}:${rows.single['n']}';
    }

    Future<TimelineLegacyPage> find(List<String> ids) async =>
        readEncryptedTimelinePage(
            path: path,
            cipher: cipher,
            fragment: key,
            sourceIdentity: await identity(),
            findEventIds: ids);
    try {
      await raw.insert('box_timeline_fragments', {
        'k': key,
        'v': jsonEncode(['old-0', 'old-1'])
      });
      expect((await find(['absent'])).positions, isEmpty);
      final cache = await factory.openDatabase('$path.timeline_pages.sqlite',
          options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey));
      await cache.delete('matrix_timeline_legacy_bloom_parts',
          where: 'part=?', whereArgs: [0]);
      await cache.close();
      expect((await find(['old-1'])).positions, {'old-1': 1},
          reason:
              'incomplete filter must rebuild rather than establish absence');
      final before = await identity();
      await raw.update(
          'box_timeline_fragments',
          {
            'v': jsonEncode(['new-0', 'old-1'])
          },
          where: 'k=?',
          whereArgs: [key]);
      expect(await identity(), isNot(before));
      expect((await find(['new-0'])).positions, {'new-0': 0},
          reason: 'equal byte length must not reuse earlier Bloom negatives');
      expect((await find(['old-0'])).positions, isEmpty);
      for (final suffix in ['', '-wal']) {
        final file = File('$path$suffix');
        if (await file.exists()) {
          expect(
              latin1.decode(await file.readAsBytes()), isNot(contains('new-0')),
              reason:
                  'SQLCipher source/WAL contains no synthetic plaintext IDs');
        }
      }
      await db.close();
      final reopened = await factory.openDatabase(path,
          options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey));
      expect(
          (await reopened.query('box_timeline_fragments',
                  where: 'k=?', whereArgs: [key]))
              .single['v'],
          jsonEncode(['new-0', 'old-1']));
      await reopened.close();
      var cancelled = false;
      final pending = readEncryptedTimelinePage(
          path: path,
          cipher: cipher,
          fragment: key,
          sourceIdentity: await Future.value('unused'),
          findEventIds: ['unknown'],
          isCancelled: () => cancelled);
      cancelled = true;
      await expectLater(pending, throwsA(isA<TimelineStorageClosed>()));
    } finally {
      await db.close();
      await folder.delete(recursive: true);
    }
  });
}
