import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/features/matrix/timeline_migration_reader.dart';
import 'indexed_timeline_storage_test.dart' show StorageClient;
import 'fixtures/delegating_sqlite_database.dart';

class _InterruptedAdoption extends DelegatingSqliteDatabase {
  _InterruptedAdoption(super.delegate);
  @override
  Future<T> transaction<T>(Future<T> Function(Transaction) action,
          {bool? exclusive}) =>
      delegate.transaction((transaction) async {
        await action(transaction);
        throw StateError('synthetic adoption interruption before commit');
      }, exclusive: exclusive);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final stage in ['timeline', 'search', 'interrupted', 'copying']) {
    test('2206 rollforward $stage refresh preserves legacy authority',
        () async {
      final folder = await Directory.systemTemp.createTemp('rollforward-');
      final path = '${folder.path}/synthetic.db';
      const cipher = 'synthetic-rollforward-only-key';
      final factory =
          createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
      final encryption =
          SQfLiteEncryptionHelper(factory: factory, path: path, cipher: cipher);
      Future<Database> open() => factory.openDatabase(path,
          options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey));
      var raw = await open();
      MatrixSdkDatabase store(Database connection) =>
          MatrixSdkDatabase('rollforward',
              database: connection,
              sqfliteFactory: factory,
              timelineMigrationReader: (key) => readEncryptedTimelineIds(
                  path: path, cipher: cipher, fragment: key));
      var db = store(raw);
      await db.open();
      var client = StorageClient(db);
      var room = Room(id: '!rollforward:synthetic', client: client);
      for (final id in [r'$old', r'$removed', r'$tombstone']) {
        await db.storeEventUpdate(
            EventUpdate(
                roomID: room.id,
                type: EventUpdateType.timeline,
                content: _event(id, 1000)),
            client);
      }
      await db.removeEvent(r'$tombstone', room.id);
      (await db.openSearchEventIds(room)).dispose();
      await db.close();

      // The released 2206 bridge restores completed normalized fragments, then
      // its legacy SDK owns writes. Recreate that on the same encrypted file.
      raw = await open();
      if (stage == 'copying') {
        await raw.update(
            'matrix_timeline_fragment_state',
            {
              'migration_state': 'copying',
              'migration_next': 1,
            },
            where: 'fragment_key=?',
            whereArgs: ['${room.id}|']);
      }
      await raw.execute('INSERT INTO box_timeline_fragments(k,v) '
          'SELECT s.fragment_key,(SELECT json_group_array(event_id) FROM '
          '(SELECT event_id FROM matrix_timeline_fragment_ids '
          'WHERE fragment_key=s.fragment_key AND epoch=s.current_epoch '
          'AND valid_to IS NULL ORDER BY seq)) '
          "FROM matrix_timeline_fragment_state s WHERE migration_state='ready' "
          'ON CONFLICT(k) DO UPDATE SET v=excluded.v');
      await raw.insert('box_client', {
        'k': 'android_2206_legacy_rollback_complete',
        'v': jsonEncode('complete'),
      });
      final legacy = jsonEncode([r'$new', r'$old', r'$missing', r'$tombstone']);
      await raw.insert(
          'box_timeline_fragments', {'k': '${room.id}|', 'v': legacy},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await raw.insert('box_events',
          {'k': '${room.id}|\$new', 'v': jsonEncode(_event(r'$new', 2000))});
      await raw.update('box_events', {'v': jsonEncode(_event(r'$old', 1500))},
          where: 'k=?', whereArgs: ['${room.id}|\$old']);
      await raw.delete('box_events',
          where: 'k=?', whereArgs: ['${room.id}|\$removed']);
      await raw.close();

      raw = await open();
      if (stage == 'interrupted') {
        final before = (await raw.query('matrix_timeline_fragment_state',
                where: 'fragment_key=?', whereArgs: ['${room.id}|']))
            .single;
        final interrupted = store(_InterruptedAdoption(raw));
        await expectLater(interrupted.open(), throwsStateError);
        expect(
            (await raw.query('matrix_timeline_fragment_state',
                    where: 'fragment_key=?', whereArgs: ['${room.id}|']))
                .single,
            before);
        expect(
            await raw.query('box_client',
                where: 'k=?',
                whereArgs: ['android_2206_legacy_rollback_complete']),
            hasLength(1));
        await interrupted.close();
        raw = await open();
      }
      db = store(raw);
      await db.open();
      client = StorageClient(db);
      room = Room(id: room.id, client: client);
      try {
        if (stage == 'timeline') {
          expect(await db.getEventIdList(room),
              [r'$new', r'$old', r'$missing', r'$tombstone']);
        }
        final search = await db.openSearchEventIds(room);
        try {
          final found = <String>[];
          while (search.hasMore) {
            found.addAll(await search.page(search.nextOffset, 256));
          }
          expect(found, [r'$new', r'$old', r'$missing']);
        } finally {
          search.dispose();
        }
        expect(
            (await raw.query('box_timeline_fragments',
                    where: 'k=?', whereArgs: ['${room.id}|']))
                .single['v'],
            legacy);
      } finally {
        await db.close();
        await folder.delete(recursive: true);
      }
    });
  }
}

Map<String, dynamic> _event(String id, int ts) => {
      'event_id': id,
      'type': EventTypes.Message,
      'sender': '@self:synthetic',
      'origin_server_ts': ts,
      'content': {'msgtype': 'm.text', 'body': 'synthetic fixture'},
    };
