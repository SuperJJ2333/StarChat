import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/src/database/sqflite_box.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Database raw;
  late BoxCollection collection;
  late Box<Map> events;
  setUp(() async {
    raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    collection = await BoxCollection.open(
        'memory-proof', {'box_events', 'box_account_data'},
        sqfliteDatabase: raw);
    events = collection.openBox<Map>('box_events');
  });
  tearDown(() async {
    await collection.close();
  });

  test(
      'real SQLite 4500 writes and complete ordered reads retain at most 512 event rows',
      () async {
    final keys = List.generate(4500, (i) => 'room|event-$i');
    await collection.transaction(() async {
      for (var i = 0; i < keys.length; i++) {
        await events.put(keys[i], {'index': i, 'body': 'synthetic'});
      }
    });
    expect(events.cachedEntryCount, lessThanOrEqualTo(512));
    expect((await raw.query('box_events')).length, 4500);
    final requested = [...keys, keys.first, 'missing', keys.last];
    final values = await events.getAll(requested);
    expect(values.length, 4503);
    for (var i = 0; i < 4500; i++) {
      expect(values[i]!['index'], i);
    }
    expect(values[4500]!['index'], 0);
    expect(values[4501], isNull);
    expect(values[4502]!['index'], 4499);
    expect(events.cachedEntryCount, lessThanOrEqualTo(512));
    expect(await events.getAllKeys(), containsAll(keys));
    expect((await events.getAllValues()).length, 4500);
    expect(events.cachedEntryCount, lessThanOrEqualTo(512));
  });

  test('event byte budget rejects oversized rows without losing SQLite data',
      () async {
    final body = List.filled(64 * 1024, 'x').join();
    await collection.transaction(() async {
      for (var i = 0; i < 100; i++) {
        await events.put('payload-$i', {'body': body});
      }
    });
    expect(events.cachedEstimatedBytes, lessThanOrEqualTo(4 * 1024 * 1024));
    await events.clear();
    final oversized = List.filled(300 * 1024, 'x').join();
    await events.put('large', {'body': oversized});
    expect(events.cachedEntryCount, 0);
    expect((await events.get('large'))!['body'], oversized);
    expect(events.cachedEntryCount, 0);
    expect((await events.getAll(['large'])).single!['body'], oversized);
    expect(events.cachedEntryCount, 0);
    expect((await raw.query('box_events')).length, 1);
  });

  test(
      'pending writes deletes clear and rollback override evicted and mirror caches',
      () async {
    final mirror = collection.openBox<Map>('box_events');
    await events.put('old', {'value': 'committed'});
    expect((await mirror.get('old'))!['value'], 'committed');
    await expectLater(collection.transaction(() async {
      await events.put('old', {'value': 'pending'});
      for (var i = 0; i < 600; i++) {
        await events.put('new-$i', {'value': i});
      }
      expect((await events.get('old'))!['value'], 'pending');
      expect((await mirror.get('old'))!['value'], 'pending');
      final requested = ['old', ...List.generate(600, (i) => 'new-$i'), 'old'];
      final all = await events.getAll(requested);
      expect(all.first!['value'], 'pending');
      expect(all.last!['value'], 'pending');
      expect((await mirror.getAllValues()).length, 601);
      await events.delete('old');
      expect(await mirror.get('old'), isNull);
      expect(await mirror.getAll(['old', 'new-0']), [
        null,
        {'value': 0}
      ]);
      await events.clear();
      await events.put('after-clear', {'value': 'kept'});
      expect(await mirror.getAllKeys(), ['after-clear']);
      expect(await mirror.getAllValues(), {
        'after-clear': {'value': 'kept'}
      });
      expect(await mirror.getAll(['old', 'new-0', 'after-clear']), [
        null,
        null,
        {'value': 'kept'}
      ]);
      throw StateError('rollback');
    }), throwsStateError);
    expect(await events.get('old'), {'value': 'committed'});
    expect(await mirror.get('old'), {'value': 'committed'});
    expect(await events.get('new-0'), isNull);
    expect((await raw.query('box_events')).length, 1);
  });

  test('negative lookups are bounded and LRU refresh preserves recent rows',
      () async {
    for (var i = 0; i < 1500; i++) {
      expect(await events.get('missing-$i'), isNull);
    }
    expect(events.cachedEntryCount, lessThanOrEqualTo(512));
    await events.clear();
    for (var i = 0; i < 512; i++) {
      await events.put('row-$i', {'value': i});
    }
    await events.get('row-0');
    await events.put('row-512', {'value': 512});
    for (final id in ['row-0', 'row-1']) {
      await raw.update(
          'box_events',
          {
            'v': jsonEncode({'value': 'disk'})
          },
          where: 'k = ?',
          whereArgs: [id]);
    }
    expect(await events.get('row-0'), {'value': 0});
    expect(await events.get('row-1'), {'value': 'disk'});
  });

  test('nontransaction clear and delete do not leave a stale pending overlay',
      () async {
    await events.put('row', {'value': 'first'});
    await events.delete('row');
    await events.put('row', {'value': 'replacement'});
    expect(await events.getAllTransient(['row']), [
      {'value': 'replacement'}
    ]);
    await events.clear();
    await events.put('after', {'value': 'persisted'});
    expect(await events.getAllTransient(['after']), [
      {'value': 'persisted'}
    ]);
  });

  test('account boxes retain their existing caching policy', () async {
    final account = collection.openBox<Map>('box_account_data');
    await collection.transaction(() async {
      for (var i = 0; i < 600; i++) {
        await account.put('key-$i', {'value': i});
      }
    });
    expect(account.cachedEntryCount, 600);
  });
}
