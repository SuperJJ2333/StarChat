import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'timeline_migration_reader.dart';

const _cipher = 'synthetic-independent-review';
const _fragment = '!review:local|';

class _Fixture {
  _Fixture(this.path, this.raw, this.factory, this.encryption, this.identity);
  final String path;
  final Database raw;
  final DatabaseFactory factory;
  final SQfLiteEncryptionHelper encryption;
  String identity;
  int reads = -1;

  Future<TimelineLegacyPage> find(List<String> ids,
      {String? source, bool Function()? cancelled}) =>
      readEncryptedTimelinePage(
          path: path,
          cipher: _cipher,
          fragment: _fragment,
          sourceIdentity: source ?? identity,
          findEventIds: ids,
          isCancelled: cancelled,
          onSourceItemsRead: (value) => reads = value);

  Future<void> cacheEdit(Future<void> Function(Database) action) async {
    final cache = await factory.openDatabase('$path.timeline_pages.sqlite',
        options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey));
    try {
      await action(cache);
    } finally {
      await cache.close();
    }
  }

  Future<String> currentIdentity() async {
    final row = (await raw.rawQuery(
            'SELECT t.rowid AS r,COALESCE(v.revision,0) AS n '
            'FROM box_timeline_fragments t LEFT JOIN matrix_timeline_legacy_revision v '
            'ON v.fragment_key=t.k WHERE t.k=?', [_fragment]))
        .single;
    return '${row['r']}:${row['n']}';
  }
}

Future<void> _withFixture(
    List<String> ids, Future<void> Function(_Fixture) action) async {
  final root = Directory(
      '../../docs/verification/artifacts/2026-10-11/im-mention-pages/r7d-review/fixtures');
  await root.create(recursive: true);
  final folder = await root.createTemp('independent-');
  final path = '${folder.absolute.path}/synthetic.db';
  final factory =
      createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
  final encryption =
      SQfLiteEncryptionHelper(factory: factory, path: path, cipher: _cipher);
  final raw = await factory.openDatabase(path,
      options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey));
  final db = MatrixSdkDatabase('review', database: raw);
  await db.open();
  try {
    await raw.insert('box_timeline_fragments',
        {'k': _fragment, 'v': jsonEncode(ids)});
    final fixture = _Fixture(path, raw, factory, encryption, '');
    fixture.identity = await fixture.currentIdentity();
    await action(fixture);
  } finally {
    await db.close();
    if (!folder.absolute.path.startsWith(root.absolute.path)) {
      throw StateError('Fixture path escaped review evidence directory');
    }
    await folder.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('warm blocks preserve first duplicate ordinal and escaped boundary IDs',
      () async {
    final ids = List.generate(8195, (i) => 'id-$i');
    ids[5] = ids[1030] = ids[8194] = 'duplicate';
    ids[1023] = '引号"和反斜线\\边界';
    ids[1024] = 'emoji😀boundary';
    await _withFixture(ids, (fixture) async {
      expect((await fixture.find(['missing'])).positions, isEmpty);
      expect(fixture.reads, ids.length);
      final page = await fixture
          .find(['duplicate', ids[1023], ids[1024], 'id-8193', 'missing']);
      expect(page.positions,
          {'duplicate': 5, ids[1023]: 1023, ids[1024]: 1024, 'id-8193': 8193});
      expect(fixture.reads, lessThan(ids.length));
    });
  });

  test('all Bloom positives are still checked against exact source IDs', () async {
    final ids = List.generate(4101, (i) => 'id-$i');
    await _withFixture(ids, (fixture) async {
      await fixture.find(['missing']);
      await fixture.cacheEdit((cache) async {
        await cache.update('matrix_timeline_legacy_bloom_parts',
            {'v': Uint8List.fromList(List.filled(32768, 255))});
        await cache.update('matrix_timeline_legacy_membership_blocks',
            {'v': Uint8List.fromList(List.filled(2048, 255))});
      });
      expect((await fixture.find(['missing', 'id-4100'])).positions,
          {'id-4100': 4100});
      expect(fixture.reads, ids.length);
    });
  });

  for (final damage in ['short-block', 'wrong-count', 'missing-global-part']) {
    test('$damage falls back without losing a real tail ID', () async {
      final ids = List.generate(8195, (i) => 'id-$i');
      await _withFixture(ids, (fixture) async {
        await fixture.find(['missing']);
        await fixture.cacheEdit((cache) async {
          if (damage == 'short-block') {
            await cache.update('matrix_timeline_legacy_membership_blocks',
                {'v': Uint8List(2)},
                where: 'block_ordinal=8');
          } else if (damage == 'wrong-count') {
            await cache.update('matrix_timeline_legacy_membership_blocks',
                {'item_count': 1},
                where: 'block_ordinal=8');
          } else {
            await cache.delete('matrix_timeline_legacy_bloom_parts',
                where: 'part=0');
          }
        });
        expect((await fixture.find(['id-8194'])).positions, {'id-8194': 8194});
        expect(fixture.reads, ids.length);
      });
    });
  }

  test('same-length source rewrite rejects old generation and rebuilds safely',
      () async {
    final ids = List.generate(8195, (i) => 'id-$i');
    await _withFixture(ids, (fixture) async {
      await fixture.find(['missing']);
      final previous = fixture.identity;
      ids[8194] = 'xx-8194';
      await fixture.raw.update('box_timeline_fragments', {'v': jsonEncode(ids)},
          where: 'k=?', whereArgs: [_fragment]);
      fixture.identity = await fixture.currentIdentity();
      expect(fixture.identity, isNot(previous));
      await expectLater(fixture.find(['id-8194'], source: previous),
          throwsStateError);
      expect((await fixture.find(['xx-8194', 'id-8194'])).positions,
          {'xx-8194': 8194});
      expect((await fixture.find(['xx-8194'])).positions, {'xx-8194': 8194});
    });
  });

  test('cancelling a warm positive lookup does not poison the next lookup',
      () async {
    final ids = List.generate(65536, (i) => 'id-$i');
    await _withFixture(ids, (fixture) async {
      await fixture.find(['missing']);
      await fixture.cacheEdit((cache) async {
        await cache.update('matrix_timeline_legacy_membership_blocks',
            {'v': Uint8List.fromList(List.filled(2048, 255))});
      });
      var cancelled = false;
      final timer = Timer(const Duration(milliseconds: 150), () => cancelled = true);
      try {
        await expectLater(fixture.find(['id-65535'], cancelled: () => cancelled),
            throwsA(isA<TimelineStorageClosed>()));
      } finally {
        timer.cancel();
      }
      expect((await fixture.find(['id-65535'])).positions, {'id-65535': 65535});
    });
  }, timeout: const Timeout(Duration(minutes: 2)));
}
