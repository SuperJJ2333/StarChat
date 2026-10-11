import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'timeline_migration_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('million-ID cold negative builds bounded warm tail membership lookup',
      () async {
    final root = Directory(
        '../../docs/verification/artifacts/2026-10-11/im-mention-pages/r7d-review/fixtures');
    await root.create(recursive: true);
    final folder = await root.createTemp('membership-');
    final path = '${folder.absolute.path}/synthetic.db';
    const cipher = 'synthetic-membership-only', fragment = '!fixture:local|';
    const count = 1000000;
    final factory =
        createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
    final encryption =
        SQfLiteEncryptionHelper(factory: factory, path: path, cipher: cipher);
    final raw = await factory.openDatabase(path,
        options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey));
    final db = MatrixSdkDatabase('membership', database: raw);
    await db.open();
    try {
      await raw.insert('box_timeline_fragments', {
        'k': fragment,
        'v': jsonEncode(List.generate(count, (i) => 'old-$i'))
      });
      final row = (await raw.rawQuery(
              'SELECT t.rowid AS r,COALESCE(v.revision,0) AS n '
              'FROM box_timeline_fragments t LEFT JOIN matrix_timeline_legacy_revision v '
              'ON v.fragment_key=t.k WHERE t.k=?',
              [fragment]))
          .single;
      final identity = '${row['r']}:${row['n']}';
      var reads = -1;
      Future<TimelineLegacyPage> find(List<String> ids) =>
          readEncryptedTimelinePage(
              path: path,
              cipher: cipher,
              fragment: fragment,
              sourceIdentity: identity,
              findEventIds: ids,
              onSourceItemsRead: (value) => reads = value);
      expect((await find(['old-1023'])).positions, {'old-1023': 1023});
      expect(reads, 1024,
          reason: 'a known early ID does not force a full cold index build');
      final clock = Stopwatch()..start();
      expect((await find(['never-existed'])).positions, isEmpty);
      final coldMs = clock.elapsedMilliseconds;
      expect(reads, count);
      clock.reset();
      final tail = await find(['old-999999', 'old-500007', 'still-absent']);
      final warmMs = clock.elapsedMilliseconds;
      debugPrint('legacyMembership count=$count coldMs=$coldMs '
          'warmMs=$warmMs warmSourceItems=$reads');
      expect(tail.positions, {'old-999999': 999999, 'old-500007': 500007});
      expect(reads, lessThan(count ~/ 20),
          reason: 'a complete accelerator must not rescan the entire source');
      expect((await find(['another-absent'])).positions, isEmpty);
      expect(reads, lessThan(count ~/ 20));

      final cache = await factory.openDatabase('$path.timeline_pages.sqlite',
          options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey));
      await cache.delete('matrix_timeline_legacy_membership_blocks',
          where: 'block_ordinal=?', whereArgs: [count ~/ 1024 - 1]);
      await cache.close();
      expect((await find(['old-999999', 'old-998401'])).positions,
          {'old-999999': 999999, 'old-998401': 998401},
          reason: 'missing accelerator blocks never establish absence');
    } finally {
      await db.close();
      await folder.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
