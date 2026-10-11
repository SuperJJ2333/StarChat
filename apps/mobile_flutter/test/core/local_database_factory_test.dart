import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_store.dart';
import 'package:matrix/matrix.dart' show SQfLiteEncryptionHelper;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Map<String, Object?>> _coldOrder((String, bool) input) async {
  final (path, metadataFirst) = input;
  const owner = MediaOutboxOwner(
      accountId: '@synthetic:invalid',
      homeserver: 'https://synthetic.invalid',
      generation: 'cold-order');
  SqliteMediaOutboxStore newStore() => SqliteMediaOutboxStore(
      owner: owner,
      directory: () async => Directory(path),
      availableBytes: () async => 1 << 30,
      seal: (_, __) async {});
  var store = newStore();
  final cipherFactory =
      createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
  final cipherPath = p.join(path, 'synthetic-cipher.db');
  final encryption = SQfLiteEncryptionHelper(
      factory: cipherFactory, path: cipherPath, cipher: 'synthetic-test-key');
  Database? cipher;
  Future<void> persist() async {
    await store.persistBytes(
        txid: 'same-transaction',
        roomId: '!synthetic:invalid',
        bytes: Uint8List.fromList([1, 2, 3]),
        mimeType: 'application/octet-stream',
        filename: 'synthetic.bin');
  }

  Future<void> openCipher() async {
    cipher = await cipherFactory.openDatabase(cipherPath,
        options: OpenDatabaseOptions(
            singleInstance: false, onConfigure: encryption.applyPragmaKey));
    await cipher!.execute('CREATE TABLE IF NOT EXISTS synthetic (v INTEGER)');
  }

  try {
    if (metadataFirst) {
      await persist();
      await openCipher();
    } else {
      await openCipher();
      await persist();
    }
    final cipherVersion = await cipher!.rawQuery('PRAGMA cipher_version');
    await cipher!.insert('synthetic', {'v': 7});
    await cipher!.close();
    cipher = null;
    await store.close();
    store = newStore();
    final restored = (await store.byTxid('same-transaction'))!;
    final bytes = await (await store.verifiedSource(restored)).readAsBytes();
    await openCipher();
    var wrongKeyRejected = false;
    Database? wrongKey;
    try {
      final wrong = SQfLiteEncryptionHelper(
          factory: cipherFactory,
          path: cipherPath,
          cipher: 'incorrect-test-key');
      wrongKey = await cipherFactory.openDatabase(cipherPath,
          options: OpenDatabaseOptions(
              singleInstance: false, onConfigure: wrong.applyPragmaKey));
      await wrongKey.query('synthetic');
    } on DatabaseException {
      wrongKeyRejected = true;
    } finally {
      await wrongKey?.close();
    }
    final rows = await cipher!.query('synthetic');
    final manifest = File(p.join(path, owner.scope, 'manifest-v1.db'));
    final plainHeader = await manifest.open();
    final header = await plainHeader.read(16);
    await plainHeader.close();
    final encryptedHeader = await File(cipherPath).open();
    final cipherHeader = await encryptedHeader.read(16);
    await encryptedHeader.close();
    return {
      'cipherAvailable': cipherVersion.isNotEmpty,
      'bytes': bytes.toList(),
      'stage': restored.stage.name,
      'marker': rows.single['v'],
      'wrongKeyRejected': wrongKeyRejected,
      'metadataHeader': String.fromCharCodes(header),
      'cipherHeader': String.fromCharCodes(cipherHeader),
    };
  } finally {
    await cipher?.close();
    await store.close();
  }
}

void main() {
  for (final metadataFirst in [true, false]) {
    test(
        'cold ${metadataFirst ? 'metadata' : 'Matrix cipher'} first shares '
        'the packaged SQLCipher library without changing formats', () async {
      final artifactRoot = Directory(
          '../../docs/verification/artifacts/2026-10-11/im-media-outbox/database-fixtures');
      await artifactRoot.create(recursive: true);
      final root = await artifactRoot.createTemp('order-');
      try {
        // Each order gets a fresh Dart isolate and thus a fresh sqflite worker.
        // A second test in the same isolate would reuse the first initializer.
        final result = await Isolate.run(
            () => _coldOrder((root.absolute.path, metadataFirst)));
        expect(result['cipherAvailable'], isTrue);
        expect(result['bytes'], [1, 2, 3]);
        expect(result['stage'], 'queued');
        expect(result['marker'], 7);
        expect(result['wrongKeyRejected'], isTrue);
        expect(result['metadataHeader'], 'SQLite format 3\u0000');
        expect(result['cipherHeader'], isNot('SQLite format 3\u0000'));
      } finally {
        await root.delete(recursive: true);
      }
    });
  }
}
