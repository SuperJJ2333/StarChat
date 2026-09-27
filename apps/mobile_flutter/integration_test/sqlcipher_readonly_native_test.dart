import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/features/matrix/local_identity_preflight.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _cipher = 'synthetic-ios-preflight-key-32-bytes';
const _matrixUser = '@fixture:matrix.test';

Future<Map<String, List<int>?>> _bytesOf(String path) async {
  final state = <String, List<int>?>{};
  for (final suffix in const ['', '-wal', '-shm']) {
    final file = File('$path$suffix');
    state[suffix] = await file.exists() ? await file.readAsBytes() : null;
  }
  return state;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().defaultTestTimeout =
      const Timeout(Duration(minutes: 2));

  testWidgets('real iOS SQLCipher preflight reads WAL without touching files',
      (_) async {
    expect(Platform.isIOS, isTrue,
        reason: 'The release gate requires linked iOS SQLCipher.');
    final fixture = await Directory.systemTemp.createTemp('matrix_preflight_');
    final path = p.join(fixture.path, 'retained.sqlite');
    final factory = createDatabaseFactoryFfi(
      ffiInit: SQfLiteEncryptionHelper.ffiInit,
    );
    final encryption = SQfLiteEncryptionHelper(
      factory: factory,
      path: path,
      cipher: _cipher,
    );
    final writer = await factory.openDatabase(path,
        options: OpenDatabaseOptions(
            singleInstance: false, onConfigure: encryption.applyPragmaKey));
    try {
      expect(await writer.rawQuery('PRAGMA cipher_version'), isNotEmpty);
      await writer.execute('PRAGMA journal_mode=WAL');
      await writer.execute('PRAGMA wal_autocheckpoint=0');
      await writer
          .execute('CREATE TABLE box_client (k TEXT PRIMARY KEY, v TEXT)');
      await writer.insert('box_client', {'k': 'user_id', 'v': _matrixUser});
      await writer.insert('box_client', {'k': 'device_id', 'v': 'FIXTURE'});
      await writer
          .insert('box_client', {'k': 'olm_account', 'v': 'synthetic-pickle'});

      expect(await File('$path-wal').exists(), isTrue,
          reason: 'The fixture must exercise the real WAL sidecar.');
      final before = await _bytesOf(path);
      final record =
          await const ReadOnlySqlCipherIdentityReader().read(path, _cipher);
      final after = await _bytesOf(path);

      expect(record.hasRetainedData, isTrue);
      expect(record.matrixUserId, _matrixUser);
      expect(record.deviceId, 'FIXTURE');
      expect(record.olmAccount, 'synthetic-pickle');
      for (final suffix in const ['', '-wal', '-shm']) {
        expect(after[suffix], before[suffix],
            reason: 'Read-only preflight changed a SQLCipher file or sidecar.');
      }
    } finally {
      await writer.close();
      await fixture.delete(recursive: true);
    }
  });

  testWidgets('real iOS SQLCipher preflight does not create sidecars',
      (_) async {
    expect(Platform.isIOS, isTrue);
    final fixture = await Directory.systemTemp.createTemp('matrix_preflight_');
    final path = p.join(fixture.path, 'retained.sqlite');
    final factory = createDatabaseFactoryFfi(
      ffiInit: SQfLiteEncryptionHelper.ffiInit,
    );
    final encryption = SQfLiteEncryptionHelper(
      factory: factory,
      path: path,
      cipher: _cipher,
    );
    final writer = await factory.openDatabase(path,
        options: OpenDatabaseOptions(
            singleInstance: false, onConfigure: encryption.applyPragmaKey));
    try {
      await writer.execute('PRAGMA journal_mode=DELETE');
      await writer
          .execute('CREATE TABLE box_client (k TEXT PRIMARY KEY, v TEXT)');
      await writer.insert('box_client', {'k': 'user_id', 'v': _matrixUser});
    } finally {
      await writer.close();
    }
    try {
      final before = await _bytesOf(path);
      expect(before['-wal'], isNull);
      expect(before['-shm'], isNull);

      final record =
          await const ReadOnlySqlCipherIdentityReader().read(path, _cipher);
      final after = await _bytesOf(path);

      expect(record.matrixUserId, _matrixUser);
      for (final suffix in const ['', '-wal', '-shm']) {
        expect(after[suffix], before[suffix],
            reason: 'Read-only preflight created or changed a sidecar.');
      }
    } finally {
      await fixture.delete(recursive: true);
    }
  });

  testWidgets('real iOS reader sees retained events without a user id',
      (_) async {
    expect(Platform.isIOS, isTrue);
    final fixture = await Directory.systemTemp.createTemp('matrix_preflight_');
    final path = p.join(fixture.path, 'retained.sqlite');
    final factory = createDatabaseFactoryFfi(
      ffiInit: SQfLiteEncryptionHelper.ffiInit,
    );
    final encryption = SQfLiteEncryptionHelper(
      factory: factory,
      path: path,
      cipher: _cipher,
    );
    final writer = await factory.openDatabase(path,
        options: OpenDatabaseOptions(
            singleInstance: false, onConfigure: encryption.applyPragmaKey));
    try {
      await writer.execute('PRAGMA journal_mode=WAL');
      await writer
          .execute('CREATE TABLE box_client (k TEXT PRIMARY KEY, v TEXT)');
      await writer.insert('box_client', {'k': 'version', 'v': '1'});
      await writer
          .execute('CREATE TABLE box_events (k TEXT PRIMARY KEY, v TEXT)');
      await writer.insert('box_events', {'k': 'event', 'v': 'retained'});

      final before = await _bytesOf(path);
      final record =
          await const ReadOnlySqlCipherIdentityReader().read(path, _cipher);
      final after = await _bytesOf(path);

      expect(record.matrixUserId, isNull);
      expect(record.hasRetainedData, isTrue);
      expect(after, before);
    } finally {
      await writer.close();
      await fixture.delete(recursive: true);
    }
  });

  testWidgets('real iOS reader verifies legacy plaintext without a key',
      (_) async {
    expect(Platform.isIOS, isTrue);
    final fixture = await Directory.systemTemp.createTemp('matrix_preflight_');
    final path = p.join(fixture.path, 'legacy.sqlite');
    final factory = createDatabaseFactoryFfi(
      ffiInit: SQfLiteEncryptionHelper.ffiInit,
    );
    final writer = await factory.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    try {
      await writer
          .execute('CREATE TABLE box_client (k TEXT PRIMARY KEY, v TEXT)');
      await writer.insert('box_client', {'k': 'user_id', 'v': _matrixUser});
      await writer.insert('box_client', {'k': 'device_id', 'v': 'LEGACY'});
      await writer
          .insert('box_client', {'k': 'olm_account', 'v': 'synthetic-pickle'});
    } finally {
      await writer.close();
    }
    try {
      final before = await _bytesOf(path);
      final inspection = await MatrixLocalIdentityPreflight(
        fingerprintReader: (_, pickle) async {
          expect(pickle, 'synthetic-pickle');
          return 'matching-ed25519';
        },
      ).inspect(
        databasePath: path,
        cipher: null,
        binding: MatrixLocalBinding(
          version: 2,
          matrixUserId: _matrixUser,
          deviceId: 'LEGACY',
          homeserver: 'https://matrix.test',
          databaseGeneration: 'legacy',
          ed25519Fingerprint: 'matching-ed25519',
        ),
        expectedHomeserver: 'https://matrix.test',
        expectedUserId: _matrixUser,
      );
      final after = await _bytesOf(path);

      expect(inspection.status, MatrixLocalIdentityStatus.verifiedRetained);
      expect(inspection.requiresAuthenticatedMigration, isTrue);
      expect(after, before);
    } finally {
      await fixture.delete(recursive: true);
    }
  });
}
