import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Database raw;
  late MatrixSdkDatabase sdk;
  const marker = 'android_2206_legacy_rollback_complete';
  setUp(() async {
    raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await raw.execute(
        'CREATE TABLE box_timeline_fragments (k TEXT PRIMARY KEY, v TEXT)');
    await raw.execute('CREATE TABLE box_client (k TEXT PRIMARY KEY, v TEXT)');
    await raw.insert('box_client', {'k': 'version', 'v': jsonEncode('9')});
    await raw.insert(
        'box_client', {'k': 'sync_token', 'v': jsonEncode('synthetic-token')});
    sdk = MatrixSdkDatabase('rollback-proof',
        database: raw, sqfliteFactory: databaseFactoryFfi);
  });
  tearDown(() async {
    await raw.close();
  });
  Future<void> normalized() async {
    await raw.execute(
        'CREATE TABLE matrix_timeline_fragment_state (fragment_key TEXT PRIMARY KEY, current_epoch INTEGER, migration_state TEXT)');
    await raw.execute(
        'CREATE TABLE matrix_timeline_fragment_ids (fragment_key TEXT, epoch INTEGER, seq INTEGER, event_id TEXT, valid_to INTEGER)');
  }

  Future<void> fragment(String key, String state, List<String> ids) async {
    await raw.insert('matrix_timeline_fragment_state',
        {'fragment_key': key, 'current_epoch': 2, 'migration_state': state});
    for (var i = ids.length - 1; i >= 0; i--) {
      await raw.insert('matrix_timeline_fragment_ids', {
        'fragment_key': key,
        'epoch': 2,
        'seq': i,
        'event_id': ids[i],
        'valid_to': null
      });
    }
  }

  Future<List<dynamic>> legacy(String key) async => jsonDecode((await raw
          .query('box_timeline_fragments', where: 'k=?', whereArgs: [key]))
      .single['v']! as String) as List<dynamic>;
  test(
      'native SDK open restores ready current active order and preserves copying fragments and tokens',
      () async {
    await normalized();
    final main = TupleKey('!room:fixture', '').toString();
    final sending = TupleKey('!room:fixture', 'SENDING').toString();
    final recovery = TupleKey('!room:fixture', 'RECOVERY').toString();
    await raw.insert('box_timeline_fragments', {
      'k': main,
      'v': jsonEncode(['stale'])
    });
    await raw.insert('box_timeline_fragments', {
      'k': 'copying',
      'v': jsonEncode(['legacy-copy-source'])
    });
    await fragment(main, 'ready', ['newest', 'older']);
    await fragment(sending, 'ready', ['pending']);
    await fragment(recovery, 'ready', []);
    await fragment('copying', 'copying', ['incomplete']);
    await raw.insert('matrix_timeline_fragment_ids', {
      'fragment_key': main,
      'epoch': 1,
      'seq': 0,
      'event_id': 'old-epoch',
      'valid_to': null
    });
    await raw.insert('matrix_timeline_fragment_ids', {
      'fragment_key': main,
      'epoch': 2,
      'seq': -1,
      'event_id': 'removed',
      'valid_to': 10
    });
    await raw.execute('CREATE TABLE box_events (k TEXT PRIMARY KEY, v TEXT)');
    for (final id in ['newest', 'older', 'pending']) {
      await raw.insert('box_events', {
        'k': TupleKey('!room:fixture', id).toString(),
        'v': jsonEncode({
          'event_id': id,
          'type': 'm.room.message',
          'sender': '@sender:fixture',
          'origin_server_ts': 1,
          'content': {'msgtype': 'm.text', 'body': 'synthetic-$id'}
        }),
      });
    }
    final bodiesBefore = await raw.query('box_events');
    final idsBefore = await raw.query('matrix_timeline_fragment_ids');
    await sdk.open();
    expect(await legacy(main), ['newest', 'older']);
    expect(await legacy(sending), ['pending']);
    expect(await legacy(recovery), isEmpty);
    expect(await legacy('copying'), ['legacy-copy-source']);
    expect(await raw.query('matrix_timeline_fragment_ids'), idsBefore);
    expect(await raw.query('box_events'), bodiesBefore);
    final client = Client('rollback-public-read');
    final room = Room(id: '!room:fixture', client: client);
    expect((await sdk.getEventList(room)).map((event) => event.eventId),
        ['pending', 'newest', 'older']);
    await client.dispose();
    expect(
        (await raw.query('box_client', where: 'k=?', whereArgs: ['sync_token']))
            .single['v'],
        jsonEncode('synthetic-token'));
    expect(await raw.query('box_client', where: 'k=?', whereArgs: [marker]),
        hasLength(1));
  });
  test(
      'ready empty replaces stale index; later legacy writes survive repeated SDK open',
      () async {
    await normalized();
    await fragment('ready-empty', 'ready', []);
    await raw.insert('box_timeline_fragments', {
      'k': 'ready-empty',
      'v': jsonEncode(['stale'])
    });
    await sdk.open();
    expect(await legacy('ready-empty'), isEmpty);
    await raw.update(
        'box_timeline_fragments',
        {
          'v': jsonEncode(['sent-on-2206'])
        },
        where: 'k=?',
        whereArgs: ['ready-empty']);
    await sdk.open();
    expect(await legacy('ready-empty'), ['sent-on-2206']);
  });
  test('failure rolls back exported indexes and marker; retry can complete',
      () async {
    await normalized();
    for (final key in ['first', 'second']) {
      await fragment(key, 'ready', ['$key-new']);
      await raw.insert('box_timeline_fragments', {
        'k': key,
        'v': jsonEncode(['$key-old'])
      });
    }
    await raw.execute(
        "CREATE TRIGGER fail_export BEFORE UPDATE ON box_timeline_fragments WHEN NEW.k='second' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END");
    await expectLater(sdk.open(), throwsA(isA<DatabaseException>()));
    expect(await legacy('first'), ['first-old']);
    expect(await legacy('second'), ['second-old']);
    expect(await raw.query('box_client', where: 'k=?', whereArgs: [marker]),
        isEmpty);
    await raw.execute('DROP TRIGGER fail_export');
    await sdk.open();
    expect(await legacy('first'), ['first-new']);
  });
  test('unmodified 0.4.33 database opens without creating rollback marker',
      () async {
    await raw.insert('box_timeline_fragments', {
      'k': 'legacy-only',
      'v': jsonEncode(['original'])
    });
    await sdk.open();
    expect(await legacy('legacy-only'), ['original']);
    expect(await raw.query('box_client', where: 'k=?', whereArgs: [marker]),
        isEmpty);
  });
  test('large ready fragment exports complete ordered IDs without losing tail',
      () async {
    await normalized();
    final ids = List.generate(4500, (i) => 'event-$i');
    await fragment('large', 'ready', ids);
    await sdk.open();
    expect(await legacy('large'), ids);
  });
}
