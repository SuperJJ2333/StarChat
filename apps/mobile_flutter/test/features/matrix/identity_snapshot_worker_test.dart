import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/features/matrix/identity_snapshot_io.dart';
import 'package:liuhetong_mobile/features/matrix/local_identity_preflight.dart';
import 'package:matrix/matrix.dart';
import 'package:olm/olm.dart' as olm;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Faults are injected at the caller's verification boundaries. The actual
// copy and all hashes still run through the production worker implementation.
class _WorkerIo extends IdentitySnapshotIo {
  String? snapshotDirectory;
  final workerNames = <String?>[];
  Future<void> Function(File, File)? afterCopy;
  Future<void> Function(File)? beforeDigest;
  late final worker =
      OffloadedIdentitySnapshotIo(onWorkerCompleted: workerNames.add);
  @override
  Future<String> copyAndHash(File source, File target) async {
    snapshotDirectory = target.parent.path;
    final hash = await worker.copyAndHash(source, target);
    await afterCopy?.call(source, target);
    return hash;
  }

  @override
  Future<String> digest(File file) async {
    await beforeDigest?.call(file);
    return worker.digest(file);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File source;
  late MatrixLocalBinding binding;
  const cipher = 'synthetic-worker-cipher';
  setUp(() async {
    final base = Directory(
        '../../docs/verification/artifacts/2026-10-18/room-entry-readiness/fixtures');
    await base.create(recursive: true);
    directory = (await base.createTemp('worker-')).absolute;
    source = File('${directory.path}/identity.sqlite');
    await olm.init();
    final account = olm.Account()..create();
    try {
      final fingerprint =
          (jsonDecode(account.identity_keys()) as Map)['ed25519'] as String;
      binding = MatrixLocalBinding(
          version: 2,
          matrixUserId: '@worker:synthetic.test',
          deviceId: 'SYNTHETIC',
          homeserver: 'https://synthetic.test',
          databaseGeneration: 'synthetic-worker-generation',
          ed25519Fingerprint: fingerprint);
      final factory =
          createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
      final db = await factory.openDatabase(source.path,
          options: OpenDatabaseOptions(
              onConfigure: (db) => db.execute("PRAGMA key = '$cipher'")));
      try {
        await db
            .execute('CREATE TABLE box_client (k TEXT PRIMARY KEY, v TEXT)');
        for (final entry in {
          'user_id': binding.matrixUserId,
          'device_id': binding.deviceId,
          'olm_account': account.pickle(binding.matrixUserId),
        }.entries) {
          await db.insert('box_client', {'k': entry.key, 'v': entry.value});
        }
      } finally {
        await db.close();
      }
    } finally {
      account.free();
    }
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  for (final outcome in [
    'valid',
    'wrong-key',
    'wrong-account',
    'wrong-fingerprint'
  ]) {
    test(
        'default worker preserves real encrypted identity and rejection: $outcome',
        () async {
      final before = await source.readAsBytes();
      final preflight = MatrixLocalIdentityPreflight();
      expect((preflight.reader as ReadOnlySqlCipherIdentityReader).io,
          isA<OffloadedIdentitySnapshotIo>());
      final inspection = preflight.inspect(
          databasePath: source.path,
          cipher: outcome == 'wrong-key' ? 'synthetic-wrong-key' : cipher,
          binding: outcome == 'wrong-fingerprint'
              ? MatrixLocalBinding(
                  version: 2,
                  matrixUserId: binding.matrixUserId,
                  deviceId: binding.deviceId,
                  homeserver: binding.homeserver,
                  databaseGeneration: binding.databaseGeneration,
                  ed25519Fingerprint: 'synthetic-other-fingerprint')
              : binding,
          expectedHomeserver: binding.homeserver,
          expectedUserId: outcome == 'wrong-account'
              ? '@other:synthetic.test'
              : binding.matrixUserId);
      if (outcome == 'valid') {
        expect((await inspection).status,
            MatrixLocalIdentityStatus.verifiedRetained);
      } else {
        expect(
            await inspection.then<Object>((_) => 'unexpected-success',
                onError: (Object e) => e),
            isA<MatrixLocalIdentityPreflightException>());
      }
      expect(await source.readAsBytes(), before);
      expect(await File('${source.path}-wal').exists(), isFalse);
      expect(await File('${source.path}-shm').exists(), isFalse);
    });
  }

  for (final mutation in [
    'none',
    'source-truncate',
    'snapshot-corrupt',
    'wal-add',
    'shm-add',
    'sidecar-directory',
    'copy-failure',
    'wal-remove',
    'shm-remove',
    'source-link'
  ]) {
    test('real worker verification and cleanup: $mutation', () async {
      final before = await source.readAsBytes();
      if (mutation == 'wal-remove') {
        await File('${source.path}-wal').writeAsBytes([]);
      }
      if (mutation == 'shm-remove') {
        await File('${source.path}-shm').writeAsBytes([]);
      }
      final io = _WorkerIo();
      io.afterCopy = (file, target) async {
        if (file.path != source.path) return;
        if (mutation == 'source-truncate') await file.writeAsBytes([1, 2, 3]);
        if (mutation == 'snapshot-corrupt') {
          await target.writeAsBytes([1, 2, 3]);
        }
        if (mutation == 'sidecar-directory') {
          await Directory('${source.path}-wal').create();
        }
        if (mutation == 'copy-failure') {
          throw const FileSystemException('synthetic copy failure');
        }
      };
      io.beforeDigest = (file) async {
        if (file.path != source.path) return;
        if (mutation == 'wal-add') {
          await File('${source.path}-wal').writeAsBytes([1]);
        }
        if (mutation == 'shm-add') {
          await File('${source.path}-shm').writeAsBytes([1]);
        }
        if (mutation == 'wal-remove') await File('${source.path}-wal').delete();
        if (mutation == 'shm-remove') await File('${source.path}-shm').delete();
        if (mutation == 'source-link') {
          await Link('${source.path}-wal').create(source.path);
        }
      };
      final read =
          ReadOnlySqlCipherIdentityReader(io: io).read(source.path, cipher);
      if (mutation == 'none') {
        expect((await read).matrixUserId, binding.matrixUserId);
        expect(io.workerNames, hasLength(3));
      } else {
        await expectLater(read, throwsA(anything));
      }
      expect(io.workerNames, everyElement(startsWith('matrix-identity-')));
      expect(await Directory(io.snapshotDirectory!).exists(), isFalse);
      if (mutation != 'source-truncate') {
        expect(await source.readAsBytes(), before);
      }
    });
  }
}
