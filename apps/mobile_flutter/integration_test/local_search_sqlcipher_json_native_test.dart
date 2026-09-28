import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().defaultTestTimeout =
      const Timeout(Duration(minutes: 4));

  testWidgets('Android SQLCipher supports bounded JSON timeline reads',
      (_) async {
    expect(Platform.isAndroid, isTrue);
    final fixture = await Directory.systemTemp.createTemp('search_json_');
    final path = p.join(fixture.path, 'synthetic.sqlite');
    final factory = createDatabaseFactoryFfi(
      ffiInit: SQfLiteEncryptionHelper.ffiInit,
    );
    final encryption = SQfLiteEncryptionHelper(
      factory: factory,
      path: path,
      cipher: 'synthetic-search-probe-32-bytes',
    );
    final database = await factory.openDatabase(path,
        options: OpenDatabaseOptions(
            singleInstance: false, onConfigure: encryption.applyPragmaKey));
    final sdk =
        MatrixSdkDatabase(path, database: database, sqfliteFactory: factory);
    final client = Client('synthetic-search-native');
    try {
      expect(await database.rawQuery('PRAGMA cipher_version'), isNotEmpty);
      await sdk.open();
      final sqliteVersion =
          (await database.rawQuery('SELECT sqlite_version() AS v')).single['v'];
      for (final width in [40, 200]) {
        final ids = List<String>.generate(100000,
            (i) => 'e${i.toString().padLeft(6, '0')}-${'x' * (width - 8)}');
        final room = Room(id: '!width-$width:local', client: client);
        final key = TupleKey(room.id, '').toString();
        await database
            .insert('box_timeline_fragments', {'k': key, 'v': jsonEncode(ids)});
        final stopwatch = Stopwatch()..start();
        final metadata = await database.rawQuery(
            'SELECT json_array_length(v) AS n, length(v) AS chars '
            'FROM box_timeline_fragments WHERE k = ?',
            [key]);
        final metadataMs = stopwatch.elapsedMilliseconds;
        expect(metadata.single['n'], 100000);
        stopwatch.reset();
        final budget = MatrixSearchSnapshotBudget(maxBytes: 1);
        final snapshot = await sdk.openSearchEventIds(room, budget: budget);
        final openMs = stopwatch.elapsedMilliseconds;
        expect(budget.retainedBytes, 0);
        try {
          stopwatch.reset();
          for (var offset = 0; offset < 100000; offset += 500) {
            final page = await snapshot.page(offset, 500);
            expect(page, hasLength(500));
            if (offset == 0) expect(page.first, ids.first);
            if (offset == 99500) expect(page.last, ids.last);
          }
        } finally {
          snapshot.dispose();
        }
        final allPagesMs = stopwatch.elapsedMilliseconds;
        // Synthetic IDs only. No account, room, event, or message data leave
        // this local test; timings are emulator-specific diagnostic evidence.
        debugPrint('sqlcipher_search_json sqlite=$sqliteVersion width=$width '
            'metadata_ms=$metadataMs open_ms=$openMs '
            'sdk_200_pages_ms=$allPagesMs');
        await database
            .delete('box_timeline_fragments', where: 'k = ?', whereArgs: [key]);
      }
    } finally {
      await sdk.close();
      await client.dispose();
      await fixture.delete(recursive: true);
    }
  });
}
