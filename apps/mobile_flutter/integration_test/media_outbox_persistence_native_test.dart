import 'dart:io';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart' show SQfLiteEncryptionHelper;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_store.dart';

/// Must run on the actual Android/iOS candidate. No mocked channel/factory,
/// credentials, Matrix session, network, or media library permission required.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final metadataFirst in [true, false]) {
    testWidgets(
        'native cold ${metadataFirst ? 'metadata' : 'Matrix cipher'} '
        'first protects pending originals and preserves database formats',
        (tester) async {
      final token = RootIsolateToken.instance!;
      // Each order needs a fresh Dart isolate and hence a fresh sqflite worker.
      final result =
          await Isolate.run(() => _nativeColdOrder((token, metadataFirst)));
      expect(result['withinRoot'], isTrue);
      expect(result['stage'], 'queued');
      expect(result['preparedAsFile'], isTrue);
      expect(result['bytes'], [1, 2, 3, 4]);
      expect(result['sourceDeleted'], isTrue);
      expect(result['cipherAvailable'], isTrue);
      expect(result['marker'], 7);
      expect(result['wrongKeyRejected'], isTrue);
      expect(result['metadataHeader'], 'SQLite format 3\u0000');
      expect(result['cipherHeader'], isNot('SQLite format 3\u0000'));
    });
  }
}

Future<Map<String, Object?>> _nativeColdOrder(
    (RootIsolateToken, bool) input) async {
  final (token, metadataFirst) = input;
  BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  final root = await PendingMediaDirectory.directory();
  final owner = MediaOutboxOwner(
      accountId: '@synthetic-native:invalid',
      homeserver: 'https://synthetic.invalid',
      generation: 'synthetic-${DateTime.now().microsecondsSinceEpoch}');
  final scope = Directory(p.join(root.path, owner.scope));
  if (!p.isWithin(root.absolute.path, scope.absolute.path)) {
    throw StateError('Synthetic native scope escaped pending root');
  }
  await scope.create();
  var store = SqliteMediaOutboxStore(owner: owner);
  final cipherFactory =
      createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
  final encryption = SQfLiteEncryptionHelper(
      factory: cipherFactory,
      path: p.join(scope.path, 'synthetic-cipher.db'),
      cipher: 'synthetic-native-test-key');
  Database? cipher;
  Future<void> openCipher() async {
    cipher = await cipherFactory.openDatabase(encryption.path,
        options: OpenDatabaseOptions(
            singleInstance: false, onConfigure: encryption.applyPragmaKey));
    await cipher!.execute('CREATE TABLE IF NOT EXISTS synthetic (v INTEGER)');
  }

  try {
    if (!metadataFirst) await openCipher();
    final task = await store.persistBytes(
        txid: 'native-fixed-transaction',
        roomId: '!synthetic:invalid',
        bytes: Uint8List.fromList([1, 2, 3, 4]),
        mimeType: 'application/octet-stream',
        filename: 'synthetic.bin',
        prepared: true,
        asFile: true);
    if (metadataFirst) await openCipher();
    final cipherVersion = await cipher!.rawQuery('PRAGMA cipher_version');
    await cipher!.insert('synthetic', {'v': 7});
    await cipher!.close();
    cipher = null;
    final before = await store.verifiedSource(task);
    final withinRoot = p.isWithin(root.absolute.path, before.absolute.path);
    await store.close();
    store = SqliteMediaOutboxStore(owner: owner);
    final reopened = (await store.byTxid(task.txid))!;
    final bytes = await (await store.verifiedSource(reopened)).readAsBytes();
    await openCipher();
    var wrongKeyRejected = false;
    Database? wrongKey;
    try {
      final wrong = SQfLiteEncryptionHelper(
          factory: cipherFactory,
          path: encryption.path,
          cipher: 'incorrect-native-test-key');
      wrongKey = await cipherFactory.openDatabase(encryption.path,
          options: OpenDatabaseOptions(
              singleInstance: false, onConfigure: wrong.applyPragmaKey));
      await wrongKey.query('synthetic');
    } on DatabaseException {
      wrongKeyRejected = true;
    } finally {
      await wrongKey?.close();
    }
    final marker = (await cipher!.query('synthetic')).single['v'];
    await store.setStage(task.txid, MediaOutboxStage.canceled);
    await store.releaseTerminalSource(task.txid);
    final manifest = await File(p.join(scope.path, 'manifest-v1.db')).open();
    final header = await manifest.read(16);
    await manifest.close();
    final encryptedFile = await File(encryption.path).open();
    final cipherHeader = await encryptedFile.read(16);
    await encryptedFile.close();
    return {
      'withinRoot': withinRoot,
      'stage': reopened.stage.name,
      'preparedAsFile': reopened.prepared && reopened.asFile,
      'bytes': bytes.toList(),
      'sourceDeleted': !await before.exists(),
      'cipherAvailable': cipherVersion.isNotEmpty,
      'marker': marker,
      'wrongKeyRejected': wrongKeyRejected,
      'metadataHeader': String.fromCharCodes(header),
      'cipherHeader': String.fromCharCodes(cipherHeader),
    };
  } finally {
    await cipher?.close();
    await store.close();
    if (await scope.exists()) await scope.delete(recursive: true);
  }
}
