import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/database/sqflite_box.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:liuhetong_mobile/features/matrix/cooperative_matrix_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('transient reads keep holes and pending writes without caching rows',
      () async {
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    const table = 'box_transient_test';
    final collection = await BoxCollection.open('transient-review', {table},
        sqfliteDatabase: raw);
    final box = collection.openBox<Map>(table);
    final mirror = collection.openBox<Map>(table);
    try {
      await raw.insert(table, {
        'k': 'first',
        'v': jsonEncode({'v': 'old'})
      });
      expect(await box.getAllTransient(['first', 'missing']), [
        {'v': 'old'},
        null,
      ]);
      await raw.update(
          table,
          {
            'v': jsonEncode({'v': 'new'})
          },
          where: 'k = ?',
          whereArgs: ['first']);
      expect(await box.get('first'), {'v': 'new'},
          reason: 'transient search reads must not populate the Box cache');

      await collection.transaction(() async {
        await box.put('pending', {'v': 'inserted'});
        await box.delete('first');
        expect(await box.getAllTransient(['first', 'pending', 'missing']), [
          null,
          {'v': 'inserted'},
          null,
        ]);
        expect(await mirror.getAllTransient(['first', 'pending']), [
          null,
          {'v': 'inserted'},
        ]);
        await box.clear();
        await box.put('after-clear', {'v': 'retained'});
        expect(await box.getAllTransient(['first', 'after-clear']), [
          null,
          {'v': 'retained'},
        ]);
        expect(await mirror.getAllTransient(['first', 'after-clear']), [
          null,
          {'v': 'retained'},
        ]);
      });
      expect(await box.getAllTransient(['first', 'after-clear']), [
        null,
        {'v': 'retained'},
      ]);
    } finally {
      await collection.close();
    }
  });

  test('native timeline read-all reflects pending put/delete and reopen',
      () async {
    final fixture = await _Fixture.open();
    try {
      const table = 'box_timeline_fragments';
      final collection = await BoxCollection.open('timeline-review', {table},
          sqfliteDatabase: fixture.raw);
      final fragments = collection.openBox<List>(table);
      final mirror = collection.openBox<List>(table);
      await fragments.put('room|old', ['old']);

      await collection.transaction(() async {
        await fragments.put('room|new', ['first']);
        await fragments.put('room|new', ['final']);
        await fragments.delete('room|old');
        expect(await fragments.getAllValues(), {
          'room|new': ['final'],
        });
        expect(await mirror.getAllValues(), {
          'room|new': ['final'],
        });
        expect(await fragments.getAllKeys(), ['room|new']);
      });
      expect(await fragments.getAllValues(), {
        'room|new': ['final'],
      });

      await collection.transaction(() async {
        await fragments.clear();
        await fragments.put('room|after-clear', ['kept']);
        expect(await fragments.getAllValues(), {
          'room|after-clear': ['kept'],
        });
      });
      await fixture.reopen();
      final reopened = await BoxCollection.open('timeline-review', {table},
          sqfliteDatabase: fixture.raw);
      expect(await reopened.openBox<List>(table).getAllValues(), {
        'room|after-clear': ['kept'],
      });
    } finally {
      await fixture.close();
    }
  });

  test('cached receive burst lets event-loop heartbeat run before commit',
      () async {
    final fixture = await _Fixture.open();
    try {
      final seedIds = List.generate(10000, (index) => '\$seed-$index');
      final burstIds = List.generate(50, (index) => '\$burst-$index');
      await fixture.seed(seedIds);
      // A fully cached SDK chain only awaits already-completed Futures. Warm
      // negative event lookups too, so SQL I/O cannot mask starvation.
      await fixture.database.getEventList(fixture.room, limit: 1);
      for (final id in burstIds) {
        expect(await fixture.database.getEventById(id, fixture.room), isNull);
      }

      var heartbeatRan = false;
      var completedEvents = 0;
      var completedAtHeartbeat = -1;
      var heartbeatDuringAction = false;
      var storedBeforeCommit = -1;
      final elapsed = Stopwatch()..start();
      await fixture.database.transaction(() async {
        Timer.run(() {
          heartbeatRan = true;
          completedAtHeartbeat = completedEvents;
        });
        for (final id in burstIds) {
          await fixture.store(_message(id));
          completedEvents++;
        }
        heartbeatDuringAction = heartbeatRan;
        // Original SDK batch ownership remains intact until action returns.
        storedBeforeCommit = (await fixture.raw.query('box_events',
                columns: ['k'],
                where: 'k = ?',
                whereArgs: ['${fixture.room.id}|${burstIds.last}']))
            .length;
      });
      elapsed.stop();
      expect(heartbeatDuringAction, isTrue,
          reason: 'cached SDK persistence must yield beyond microtasks before '
              'the receive batch has finished');
      expect(storedBeforeCommit, 0);
      expect(completedAtHeartbeat, inInclusiveRange(0, 15));
      final expected = [...burstIds.reversed, ...seedIds];
      expect(
          (await fixture.database.getEventList(fixture.room))
              .map((event) => event.eventId),
          expected);
      await fixture.reopen();
      expect(
          (await fixture.database.getEventList(fixture.room))
              .map((event) => event.eventId),
          expected);
      // Replayed events stay unique and retain ordering after disk reopening.
      await fixture.database.transaction(() async {
        for (final id in burstIds) {
          await fixture.store(_message(id));
        }
      });
      expect(
          (await fixture.database.getEventList(fixture.room))
              .map((event) => event.eventId),
          expected);
      debugPrint(jsonEncode({
        'history_size': seedIds.length,
        'burst_count': burstIds.length,
        'heartbeat_during_action': heartbeatDuringAction,
        'completed_events_at_heartbeat': completedAtHeartbeat,
        'transaction_microseconds': elapsed.elapsedMicroseconds,
      }));
    } finally {
      await fixture.close();
    }
  });

  test('writer from another zone waits until original transaction commits',
      () async {
    final fixture = await _Fixture.open();
    final enter = Completer<void>();
    final finish = Completer<void>();
    var otherActionRan = false;
    // This callback is created outside the transaction zone, just like a UI
    // send action dispatched while the receive transaction yields.
    Timer.run(() async {
      await enter.future;
      try {
        await fixture.database.transaction(() async {
          otherActionRan = true;
          await fixture.store(_message(r'$other'));
        });
        finish.complete();
      } catch (error, stack) {
        finish.completeError(error, stack);
      }
    });
    try {
      await fixture.database.transaction(() async {
        enter.complete();
        for (var i = 0; i < 32; i++) {
          await fixture.store(_message('\$outer-$i'));
        }
        expect(otherActionRan, isFalse);
        expect(finish.isCompleted, isFalse);
        expect(await fixture.raw.query('box_events'), isEmpty);
      });
      await finish.future;
      expect(otherActionRan, isTrue);
      expect((await fixture.database.getEventList(fixture.room)).length, 33);
    } finally {
      await fixture.close();
    }
  });

  test('nested transaction stays atomic and action errors release the lock',
      () async {
    final fixture = await _Fixture.open();
    try {
      await fixture.database.transaction(() async {
        await fixture.database.transaction(() async {
          await fixture.store(_message(r'$nested'));
        });
        expect(await fixture.raw.query('box_events'), isEmpty);
      });
      expect((await fixture.raw.query('box_events')).length, 1);
      final failure = StateError('synthetic action failure');
      await expectLater(fixture.database.transaction(() async => throw failure),
          throwsA(same(failure)));
      // The original SDK transaction lock must be released on failure.
      await fixture.database.transaction(() async {
        await fixture.store(_message(r'$after-error'));
      });
      expect((await fixture.database.getEventList(fixture.room)).length, 2);
    } finally {
      await fixture.close();
    }
  });

  test('failed native batch restores cached event and fragment', () async {
    final fixture = await _Fixture.open();
    try {
      final failure = StateError('synthetic rollback');
      await expectLater(
        fixture.database.transaction(() async {
          await fixture.store(_message(r'$rolled-back'));
          expect(
              (await fixture.database.getEventList(fixture.room))
                  .map((event) => event.eventId),
              [r'$rolled-back']);
          throw failure;
        }),
        throwsA(same(failure)),
      );
      expect(await fixture.database.getEventById(r'$rolled-back', fixture.room),
          isNull);
      expect(await fixture.database.getEventList(fixture.room), isEmpty);
      await fixture.reopen();
      expect(await fixture.database.getEventList(fixture.room), isEmpty);
    } finally {
      await fixture.close();
    }
  });

  test(
      'owned batch pages merge bounded changes while other zones await rollback',
      () async {
    final fixture = await _Fixture.open();
    final entered = Completer<void>();
    final observerStarted = Completer<void>();
    var observerFinished = false;
    try {
      final seed = List.generate(600, (i) => 'seed-$i');
      await fixture.seed(seed);
      await fixture.database.prepareTimelineStorage([fixture.room.id]);
      // Created outside the owner zone: this read must never see its overlay.
      final observer = (() async {
        await entered.future;
        observerStarted.complete();
        final page =
            await fixture.database.getEventList(fixture.room, limit: 3);
        observerFinished = true;
        return page.map((event) => event.eventId).toList();
      })();
      final failure = StateError('synthetic paged rollback');
      await expectLater(fixture.database.transaction(() async {
        await fixture.store(_message('pending-a'));
        await fixture.store(_message('pending-b'));
        await fixture.database.removeEvent('seed-0', fixture.room.id);
        await fixture.database.removeEvent('pending-a', fixture.room.id);
        await fixture.store(_message('older'), type: EventUpdateType.history);
        expect(
            (await fixture.database.getEventList(fixture.room, limit: 3))
                .map((event) => event.eventId),
            ['pending-b', 'seed-1', 'seed-2']);
        expect(
            (await fixture.database
                    .getEventList(fixture.room, start: 1, limit: 2))
                .map((event) => event.eventId),
            ['seed-1', 'seed-2']);
        expect(await fixture.database.getEventById('pending-a', fixture.room),
            isNull);
        entered.complete();
        await observerStarted.future;
        await Future<void>.delayed(Duration.zero);
        expect(observerFinished, isFalse);
        await fixture.database.deleteTimelineForRoom(fixture.room.id);
        await fixture.store(_message('after-reset'));
        expect(
            (await fixture.database.getEventList(fixture.room, limit: 2))
                .map((event) => event.eventId),
            ['after-reset']);
        expect(
            (await fixture.database.getEventById('after-reset', fixture.room))
                ?.eventId,
            'after-reset');
        throw failure;
      }), throwsA(same(failure)));
      expect(await observer, seed.take(3));
      expect(await fixture.database.getEventById('pending-b', fixture.room),
          isNull);
      expect(await fixture.database.getEventById('after-reset', fixture.room),
          isNull);
      expect(
          (await fixture.database.getEventList(fixture.room))
              .map((event) => event.eventId),
          seed);
      await fixture.reopen();
      expect(
          (await fixture.database.getEventList(fixture.room, limit: 3))
              .map((event) => event.eventId),
          seed.take(3));
    } finally {
      await fixture.close();
    }
  });

  test('commit failure clears cache before a later standalone write', () async {
    final fixture = await _Fixture.open();
    try {
      await fixture.raw.execute('PRAGMA query_only = ON');
      await expectLater(
        fixture.database.transaction(() async {
          await fixture.store(_message(r'$uncommitted'));
        }),
        throwsA(isA<DatabaseException>()),
      );
      expect(await fixture.database.getEventById(r'$uncommitted', fixture.room),
          isNull);
      await fixture.raw.execute('PRAGMA query_only = OFF');
      await fixture.store(_message(r'$standalone'));
      await fixture.reopen();
      expect(
          (await fixture.database.getEventList(fixture.room))
              .map((event) => event.eventId),
          [r'$standalone']);
    } finally {
      await fixture.close();
    }
  });

  test('nested action joins the outer native batch', () async {
    final fixture = await _Fixture.open();
    try {
      await fixture.database.transaction(() async {
        await fixture.store(_message(r'$outer'));
        await fixture.database.transaction(() async {
          await fixture.store(_message(r'$nested'));
        });
        expect(await fixture.raw.query('box_events'), isEmpty);
      });
      expect(
          (await fixture.database.getEventList(fixture.room))
              .map((event) => event.eventId),
          [r'$nested', r'$outer']);
      await fixture.reopen();
      expect(
          (await fixture.database.getEventList(fixture.room))
              .map((event) => event.eventId),
          [r'$nested', r'$outer']);
    } finally {
      await fixture.close();
    }
  });

  test('caught nested failure still aborts the outer native batch', () async {
    final fixture = await _Fixture.open();
    try {
      await expectLater(
        fixture.database.transaction(() async {
          await fixture.store(_message(r'$outer'));
          try {
            await fixture.database.transaction(() async {
              await fixture.store(_message(r'$inner'));
              throw StateError('nested failure');
            });
          } on StateError catch (error) {
            expect(error.message, 'nested failure');
          }
          await fixture.store(_message(r'$after'));
        }),
        throwsStateError,
      );
      expect(await fixture.raw.query('box_events'), isEmpty);
      expect(await fixture.database.getEventList(fixture.room), isEmpty);
      await fixture.reopen();
      expect(await fixture.database.getEventList(fixture.room), isEmpty);
    } finally {
      await fixture.close();
    }
  });

  test(
      'event and commit failures propagate while the transaction lock releases',
      () async {
    final fixture = await _Fixture.open();
    try {
      await expectLater(fixture.database.transaction(() async {
        await fixture.store({..._message(r'$invalid'), 'status': 999});
      }), throwsA(isA<RangeError>()));
      expect(await fixture.raw.query('box_events'), isEmpty);

      await fixture.raw.execute('PRAGMA query_only = ON');
      await expectLater(fixture.database.transaction(() async {
        await fixture.store(_message(r'$read-only'));
      }), throwsA(isA<DatabaseException>()));
      expect(await fixture.raw.query('box_events'), isEmpty);
      await fixture.raw.execute('PRAGMA query_only = OFF');
      // The next real transaction must still run, using its own SDK batch.
      await fixture.database.transaction(() async {
        await fixture.store(_message(r'$after-commit-error'));
      });
      expect((await fixture.raw.query('box_events')).length, 1);
    } finally {
      await fixture.close();
    }
  });

  test(
      'redaction and encrypted source retention survive stale replay and reopen',
      () async {
    final fixture = await _Fixture.open();
    Map<String, dynamic> encrypted() => {
          ..._message(r'$encrypted'),
          'type': EventTypes.Encrypted,
          'content': {
            'algorithm': 'm.megolm.v1.aes-sha2',
            'ciphertext': 'synthetic-fixture',
          },
        };
    try {
      await fixture.database.transaction(() async {
        await fixture.store(encrypted());
      });
      await fixture.database.transaction(() async {
        await fixture.store({
          ..._message(r'$recall'),
          'type': EventTypes.Redaction,
          'content': {'redacts': r'$encrypted'},
        });
        await fixture.store(encrypted(), type: EventUpdateType.history);
        await fixture.store(_message(r'$older'), type: EventUpdateType.history);
      });
      expect(
          (await fixture.database.getEventList(fixture.room))
              .map((event) => event.eventId),
          [r'$recall', r'$encrypted', r'$older']);
      await fixture.reopen();
      expect(
          (await fixture.database.getEventList(fixture.room))
              .map((event) => event.eventId),
          [r'$recall', r'$encrypted', r'$older']);
      final event =
          await fixture.database.getEventById(r'$encrypted', fixture.room);
      expect(event!.redacted, isTrue);
      expect(event.type, EventTypes.Encrypted);
      expect(event.content, isEmpty);
      expect(event.originalSource, isNull);
    } finally {
      await fixture.close();
    }
  });

  test('sending transaction reconciliation and synced status remain SDK owned',
      () async {
    final fixture = await _Fixture.open();
    try {
      await fixture.database.transaction(() async {
        await fixture.store({
          ..._message(r'$txn'),
          'status': EventStatus.sending.intValue,
          'unsigned': <String, dynamic>{'transaction_id': r'$txn'},
        });
      });
      expect((await fixture.database.getEventList(fixture.room)).single.status,
          EventStatus.sending);
      await fixture.database.transaction(() async {
        await fixture.store({
          ..._message(r'$synced'),
          'unsigned': <String, dynamic>{'transaction_id': r'$txn'},
        });
      });
      expect(
          await fixture.database.getEventById(r'$txn', fixture.room), isNull);
      expect((await fixture.database.getEventList(fixture.room)).single.eventId,
          r'$synced');
      await fixture.reopen();
      final stored = (await fixture.database.getEventList(fixture.room)).single;
      expect(stored.eventId, r'$synced');
      expect(stored.status, EventStatus.synced);
    } finally {
      await fixture.close();
    }
  });
}

Map<String, dynamic> _message(String id) => {
      'event_id': id,
      'type': EventTypes.Message,
      'sender': '@sender:synthetic',
      'origin_server_ts': 123,
      'content': {'msgtype': 'm.text', 'body': 'synthetic fixture'},
    };

class _Fixture {
  _Fixture(this.directory, this.path, this.raw, this.database);

  final Directory directory;
  final String path;
  Database raw;
  MatrixSdkDatabase database;
  final client = Client('cooperative-database-fixture');
  late final room = Room(id: '!cooperative:synthetic', client: client);

  static Future<_Fixture> open() async {
    final root = Directory(
        '../../docs/verification/artifacts/2026-10-08/history-interaction-fix/storage/fixtures/cooperative');
    await root.create(recursive: true);
    final directory = await root.createTemp('cooperative-');
    final path = '${directory.path}${Platform.pathSeparator}matrix.sqlite';
    final raw = await databaseFactoryFfi.openDatabase(path);
    final database = _database(path, raw);
    await database.open();
    return _Fixture(directory, path, raw, database);
  }

  static MatrixSdkDatabase _database(String path, Database raw) {
    // Reproduce the original defect with exactly the same fixture and checks.
    // This switch belongs only to this test, never to application construction.
    if (const bool.fromEnvironment('COOPERATIVE_SDK_BASELINE')) {
      return MatrixSdkDatabase(path,
          database: raw, sqfliteFactory: databaseFactoryFfi);
    }
    return CooperativeMatrixDatabase(path,
        database: raw, sqfliteFactory: databaseFactoryFfi);
  }

  Future<void> seed(List<String> ids) async {
    final batch = raw.batch();
    for (final id in ids) {
      batch.insert('box_events', {
        'k': '${room.id}|$id',
        'v': jsonEncode(_message(id)),
      });
    }
    batch.insert('box_timeline_fragments', {
      'k': '${room.id}|',
      'v': jsonEncode(ids),
    });
    await batch.commit(noResult: true);
  }

  Future<void> store(Map<String, dynamic> source,
          {EventUpdateType type = EventUpdateType.timeline}) =>
      database.storeEventUpdate(
          EventUpdate(roomID: room.id, type: type, content: source), client);

  Future<void> reopen() async {
    await database.close();
    raw = await databaseFactoryFfi.openDatabase(path);
    database = _database(path, raw);
    await database.open();
  }

  Future<void> close() async {
    await database.close();
    await client.dispose();
    final approvedRoot = Directory(
            '../../docs/verification/artifacts/2026-10-08/history-interaction-fix/storage/fixtures/cooperative')
        .absolute
        .path;
    if (!directory.absolute.path
        .startsWith('$approvedRoot${Platform.pathSeparator}')) {
      throw StateError('fixture path outside approved evidence directory');
    }
    await databaseFactoryFfi.deleteDatabase(path);
    await directory.delete();
  }
}
