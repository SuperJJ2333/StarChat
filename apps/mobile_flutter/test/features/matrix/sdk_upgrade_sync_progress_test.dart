import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/database/sqflite_box.dart';
import 'package:matrix/src/database/timeline_id_store.dart';
import 'package:matrix/src/database/retained_search_store.dart';
import 'package:olm/olm.dart' as olm;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/features/matrix/timeline_migration_reader.dart';

class _UpgradeClient extends Client {
  _UpgradeClient(this.store, Map<String, Object?> response)
      : super('upgrade-progress', httpClient: MockClient((request) async {
          final body = request.url.path.endsWith('/filter')
              ? <String, Object?>{'filter_id': 'synthetic-filter'}
              : request.url.path.endsWith('/keys/query')
                  ? <String, Object?>{'device_keys': <String, Object>{}}
                  : response;
          return http.Response(jsonEncode(body), 200,
              headers: {'content-type': 'application/json'});
        })) {
    homeserver = Uri.parse('https://synthetic.test');
    accessToken = 'synthetic-fixture-token';
    backgroundSync = false;
    syncErrorTimeoutSec = 0;
  }

  final MatrixSdkDatabase store;
  @override
  String get userID => '@self:synthetic';
  @override
  DatabaseApi get database => store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(SQfLiteEncryptionHelper.ffiInit);

  for (final limited in [false, true]) {
    test(
        limited
            ? 'real sync replaces a limited legacy fragment without copying discarded history'
            : 'real sync receipt-only room does not migrate unrelated legacy history',
        () async {
      final raw = await createDatabaseFactoryFfi(
              ffiInit: SQfLiteEncryptionHelper.ffiInit)
          .openDatabase(inMemoryDatabasePath);
      final release = Completer<void>();
      final reads = <String>[];
      const roomId = '!legacy:synthetic';
      final db = MatrixSdkDatabase('upgrade', database: raw,
          timelineMigrationReader: (key) async* {
        reads.add(key);
        if (key == '$roomId|') {
          await release.future;
          yield [r'$old'];
        } else if (key == '$roomId|SENDING') {
          yield [r'$pending'];
        } else {
          yield [r'$recover'];
        }
      });
      await db.open();
      await raw.insert('box_timeline_fragments', {
        'k': '$roomId|',
        'v': jsonEncode([r'$old'])
      });
      if (limited) {
        for (final suffix in ['SENDING', 'RECOVERY']) {
          await raw.insert('box_timeline_fragments', {
            'k': '$roomId|$suffix',
            'v': jsonEncode([suffix == 'SENDING' ? r'$pending' : r'$recover']),
          });
        }
      }
      final update = <String, Object?>{
        'timeline': {
          'limited': limited,
          'prev_batch': 'synthetic-backwards',
          'events': limited ? [_message(r'$new')] : <Object>[],
        },
        'ephemeral': {'events': <Object>[]},
      };
      final client = _UpgradeClient(db, {
        'next_batch': 'synthetic-next',
        'rooms': {
          'join': {
            roomId: update,
            '!small:synthetic': {
              'timeline': {
                'events': [_message(r'$small')],
                'limited': false
              },
            },
          },
        },
        'device_one_time_keys_count': <String, Object>{},
      });
      final statuses = <SyncStatus>[];
      final subscription = client.onSyncStatus.stream
          .listen((event) => statuses.add(event.status));
      Future<void>? syncing;
      try {
        // Exercise the real sync transaction; handleSync utility alone does
        // not represent the application's first-sync preflight.
        syncing = client.oneShotSync();
        await expectLater(
            syncing.timeout(const Duration(milliseconds: 600)), completes,
            reason: 'obsolete history must not delay this sync response');
        await Future<void>.delayed(Duration.zero);
        expect(statuses, contains(SyncStatus.finished));
        expect(reads, isNot(contains('$roomId|')));
        final room = client.getRoomById(roomId);
        expect(room, isNotNull);
        expect(await db.getEventIdList(client.getRoomById('!small:synthetic')!),
            [r'$small']);
        if (limited) {
          expect(await db.getEventIdList(room!, limit: 30), [r'$new']);
          expect(await db.getEventIdList(room, includeSending: true, limit: 30),
              [r'$pending', r'$new']);
          expect(reads, containsAll(['$roomId|SENDING', '$roomId|RECOVERY']));
        } else {
          expect((await raw.query('box_timeline_fragments')).single['v'],
              jsonEncode([r'$old']));
        }
      } finally {
        release.complete();
        await syncing?.timeout(const Duration(seconds: 5));
        await subscription.cancel();
        await client.dispose();
        await db.close();
      }
    });
  }

  test('limited sync retains missing legacy payloads for later local search',
      () async {
    final raw =
        await createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit)
            .openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('missing', database: raw);
    await db.open();
    const roomId = '!missing:synthetic';
    await raw.insert('box_timeline_fragments', {
      'k': '$roomId|',
      'v': jsonEncode([r'$missing', r'$present']),
    });
    await raw.insert('box_events', {
      'k': '$roomId|\$present',
      'v': jsonEncode(_message(r'$present')),
    });
    final client = _UpgradeClient(db, _limitedResponse(roomId));
    try {
      await client.oneShotSync();
      final room = client.getRoomById(roomId)!;
      final search = await db.openSearchEventIds(room);
      try {
        final ids = await search.page(0, 30);
        expect(ids, containsAll([r'$missing', r'$present', r'$new']));
        expect((await db.getSearchEventsByIds(room, [r'$missing'])).single,
            isNull);
      } finally {
        search.dispose();
      }
    } finally {
      await client.dispose();
      await db.close();
    }
  });

  test('limited sync supersedes an overlapping legacy snapshot migration',
      () async {
    final raw =
        await createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit)
            .openDatabase(inMemoryDatabasePath);
    final entered = Completer<void>(), release = Completer<void>();
    final db = MatrixSdkDatabase('overlap', database: raw,
        timelineMigrationReader: (key) async* {
      entered.complete();
      await release.future;
      yield [r'$old'];
    });
    await db.open();
    const roomId = '!overlap:synthetic';
    await raw.insert('box_timeline_fragments', {
      'k': '$roomId|',
      'v': jsonEncode([r'$old'])
    });
    final client = _UpgradeClient(db, _limitedResponse(roomId));
    final room = Room(id: roomId, client: client);
    final opening = db.openTimelineIdSnapshot(room);
    try {
      await entered.future;
      await client.oneShotSync().timeout(const Duration(milliseconds: 600));
      expect(
          await db
              .getEventIdList(room, limit: 30)
              .timeout(const Duration(milliseconds: 600)),
          [r'$new']);
      release.complete();
      final snapshot = await opening;
      expect((await snapshot.next()).ids, [r'$new']);
      snapshot.dispose();
      expect(await db.getEventIdList(room, limit: 30), [r'$new']);
    } finally {
      if (!release.isCompleted) release.complete();
      (await opening).dispose();
      await client.dispose();
      await db.close();
    }
  });

  test('failed limited replacement rolls back epoch and events together',
      () async {
    final raw =
        await createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit)
            .openDatabase(inMemoryDatabasePath);
    final db = MatrixSdkDatabase('rollback', database: raw);
    await db.open();
    const roomId = '!rollback:synthetic';
    await raw.insert('box_timeline_fragments', {
      'k': '$roomId|',
      'v': jsonEncode([r'$old'])
    });
    final client = _UpgradeClient(db, _limitedResponse(roomId));
    final marker = StateError('synthetic transaction rejection');
    try {
      await expectLater(db.transaction(() async {
        await db.deleteTimelineForRoom(roomId);
        await db.storeEventUpdate(
            EventUpdate(
                roomID: roomId,
                type: EventUpdateType.timeline,
                content: _message(r'$new')),
            client);
        throw marker;
      }), throwsA(same(marker)));
      expect(
          await db.getEventIdList(Room(id: roomId, client: client)), [r'$old']);
      expect(await raw.query('box_events'), isEmpty);
    } finally {
      await client.dispose();
      await db.close();
    }
  });

  test('encrypted half-migrated reopen preserves displaced missing IDs',
      () async {
    final folder = await Directory.systemTemp.createTemp('upgrade-half-');
    final path = '${folder.path}/synthetic.db';
    const cipher = 'synthetic-test-only-upgrade-key';
    final factory =
        createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
    final encryption =
        SQfLiteEncryptionHelper(factory: factory, path: path, cipher: cipher);
    Future<Database> open() => factory.openDatabase(path,
        options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey));
    var raw = await open();
    final ids = List.generate(512, (i) => 'synthetic-id-$i');
    const roomId = '!half:synthetic';
    var db = MatrixSdkDatabase('half', database: raw,
        timelineMigrationReader: (key) async* {
      yield ids.take(256).toList();
      throw StateError('synthetic interruption');
    });
    await db.open();
    await raw.insert(
        'box_timeline_fragments', {'k': '$roomId|', 'v': jsonEncode(ids)});
    await expectLater(db.prepareTimelineStorage([roomId]), throwsStateError);
    await db.close();
    raw = await open();
    db = MatrixSdkDatabase('half',
        database: raw,
        timelineMigrationReader: (key) => readEncryptedTimelineIds(
            path: path, cipher: cipher, fragment: key));
    await db.open();
    final client = _UpgradeClient(db, _limitedResponse(roomId));
    try {
      await client.oneShotSync();
      final room = client.getRoomById(roomId)!;
      expect(await db.getEventIdList(room), [r'$new']);
      final search = await db.openSearchEventIds(room);
      try {
        final retained = <String>[];
        while (search.hasMore) {
          retained.addAll(await search.page(search.nextOffset, 256));
        }
        expect(retained.toSet(), {...ids, r'$new'});
      } finally {
        search.dispose();
      }
    } finally {
      await client.dispose();
      await db.close();
      await folder.delete(recursive: true);
    }
  });

  test('queued clear rejects deferred legacy page after gate acquisition',
      () async {
    final raw =
        await createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit)
            .openDatabase(inMemoryDatabasePath);
    final collection = await BoxCollection.open(
        'clear-race', {'box_timeline_fragments', 'box_events'},
        sqfliteDatabase: raw);
    final timeline = TimelineIdStore(collection, null);
    await timeline.open();
    final retained = RetainedSearchStore(collection, null);
    await retained.open();
    final entered = Completer<void>(), pageRelease = Completer<void>();
    final gateEntered = Completer<void>(), gateRelease = Completer<void>();
    final preparing = retained
        .prepare('synthetic-room', () async => ListTimelineIdSnapshot([]),
            legacy: () async* {
      entered.complete();
      await pageRelease.future;
      yield [r'$missing'];
    });
    final rejected = expectLater(preparing, throwsStateError);
    await entered.future;
    final holding = collection.transaction(() async {
      gateEntered.complete();
      await gateRelease.future;
    });
    await gateEntered.future;
    final clearing =
        collection.transaction(() => retained.clear(room: 'synthetic-room'));
    pageRelease.complete();
    await Future<void>.delayed(Duration.zero);
    gateRelease.complete();
    await Future.wait([holding, clearing, rejected]);
    expect(await raw.query('matrix_retained_search_rows'), isEmpty);
    await retained.close();
    await timeline.close();
    await collection.close();
  });

  test('restored account loads cached rooms before its first limited sync',
      () async {
    final factory =
        createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
    final raw = await factory.openDatabase(inMemoryDatabasePath);
    const roomId = '!cached-upgrade:synthetic';
    var legacyReads = 0;
    final db = MatrixSdkDatabase('cached-upgrade',
        database: raw,
        sqfliteFactory: factory, timelineMigrationReader: (key) async* {
      legacyReads++;
      throw StateError('obsolete main must not be migrated during first sync');
    });
    await db.open();
    await olm.init();
    final account = olm.Account()..create();
    final pickle = account.pickle('@self:synthetic');
    account.free();
    await db.insertClient(
        'cached-upgrade',
        'https://synthetic.test',
        'synthetic-fixture-token',
        null,
        null,
        '@self:synthetic',
        'SYNTHETIC',
        'fixture',
        'synthetic-before',
        pickle);
    await raw.insert('box_timeline_fragments', {
      'k': '$roomId|',
      'v': jsonEncode([r'$old'])
    });
    final seed = Client('synthetic-seed');
    await raw.insert('box_rooms', {
      'k': roomId,
      'v': jsonEncode(Room(id: roomId, client: seed).toJson()),
    });
    final response = Completer<http.Response>();
    final requested = Completer<void>();
    final client = Client('cached-upgrade',
        databaseBuilder: (_) async => db,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/sync')) {
            if (!requested.isCompleted) requested.complete();
            return response.future;
          }
          return http.Response(
              jsonEncode({
                'filter_id': 'synthetic-filter',
                'device_keys': <String, Object>{},
                'one_time_key_counts': {'signed_curve25519': 100},
              }),
              200,
              headers: {'content-type': 'application/json'});
        }))
      ..backgroundSync = false;
    try {
      await client.init(waitForFirstSync: false);
      expect(client.getRoomById(roomId), isNotNull);
      await requested.future;
      response.complete(http.Response(jsonEncode(_limitedResponse(roomId)), 200,
          headers: {'content-type': 'application/json'}));
      await client.oneShotSync().timeout(const Duration(seconds: 2));
      expect(await db.getEventIdList(client.getRoomById(roomId)!), [r'$new']);
      expect(legacyReads, 0);
    } finally {
      if (!response.isCompleted) {
        response.complete(http.Response(
            jsonEncode(_limitedResponse(roomId)), 200,
            headers: {'content-type': 'application/json'}));
      }
      await client.dispose();
      await seed.dispose();
    }
  });
}

Map<String, Object?> _limitedResponse(String roomId) => {
      'next_batch': 'synthetic-next',
      'rooms': {
        'join': {
          roomId: {
            'timeline': {
              'limited': true,
              'prev_batch': 'synthetic-backwards',
              'events': [_message(r'$new')],
            },
          },
        },
      },
      'device_one_time_keys_count': <String, Object>{},
    };

Map<String, Object?> _message(String id) => {
      'event_id': id,
      'sender': '@other:synthetic',
      'origin_server_ts': 1000,
      'type': EventTypes.Message,
      'content': {'msgtype': 'm.text', 'body': 'synthetic fixture'},
    };
