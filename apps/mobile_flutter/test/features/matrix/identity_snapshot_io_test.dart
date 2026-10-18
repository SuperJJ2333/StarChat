import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/identity_snapshot_io.dart';
import 'package:liuhetong_mobile/features/matrix/local_identity_preflight.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _MeteredIo extends IdentitySnapshotIo {
  int bytes = 0;
  int reads = 0;
  int maxChunk = 0;
  @override
  Stream<List<int>> read(File file) {
    reads++;
    return super.read(file).map((chunk) {
      bytes += chunk.length;
      if (chunk.length > maxChunk) maxChunk = chunk.length;
      return chunk;
    });
  }
}

// Reject an unmetered second source-copy pass. Production File supports both.
class _StreamOnlyFile implements File {
  _StreamOnlyFile(this.file);
  final File file;
  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      file.openRead(start, end);
  @override
  String get path => file.path;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected nonstreaming source I/O');
}

class _AdversarialIo extends IdentitySnapshotIo {
  Future<void> Function(File, File)? afterCopy;
  Future<void> Function(File)? beforeDigest;
  String? snapshotDirectory;
  @override
  Future<String> digest(File file) async {
    await beforeDigest?.call(file);
    return super.digest(file);
  }

  @override
  Future<String> copyAndHash(File source, File target) async {
    snapshotDirectory = target.parent.path;
    final hash = await super.copyAndHash(source, target);
    await afterCopy?.call(source, target);
    return hash;
  }
}

class _MidCopyIo extends _AdversarialIo {
  _MidCopyIo(this.sourcePath, this.fail);
  final String sourcePath;
  final bool fail;
  bool injected = false;
  @override
  Stream<List<int>> read(File file) async* {
    await for (final chunk in super.read(file)) {
      yield chunk;
      if (!injected && file.path == sourcePath) {
        injected = true;
        if (fail) {
          throw const FileSystemException('fixture midstream read failure');
        }
        final bytes = await file.readAsBytes();
        bytes[0] ^= 1; // already copied: guarantees final source mismatch
        bytes[bytes.length - 1] ^= 1; // a byte not yet read by the stream
        await file.writeAsBytes(bytes, flush: true);
      }
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('production default copy/hash run on a worker and preserve bytes',
      () async {
    expect(const ReadOnlySqlCipherIdentityReader().io,
        isA<OffloadedIdentitySnapshotIo>());
    final directory = await Directory.systemTemp.createTemp('identity_worker_');
    final workerNames = <String?>[];
    try {
      final source = File('${directory.path}/source');
      final target = File('${directory.path}/copy');
      final bytes = List<int>.generate(1024 * 1024, (i) => i % 251);
      await source.writeAsBytes(bytes);
      final io =
          OffloadedIdentitySnapshotIo(onWorkerCompleted: workerNames.add);
      final copied = await io.copyAndHash(source, target);
      expect(copied, sha256.convert(bytes).toString());
      expect(await io.digest(target), copied);
      expect(await io.digest(source), copied);
      expect(await source.readAsBytes(), bytes);
      expect(await target.readAsBytes(), bytes);
      expect(workerNames, hasLength(3));
      expect(workerNames, everyElement(isNot(Isolate.current.debugName)));
      expect(workerNames, everyElement(startsWith('matrix-identity-')));
      await expectLater(
          io.copyAndHash(File('${directory.path}/missing'), target),
          throwsA(isA<FileSystemException>()));
      await expectLater(io.digest(File('${directory.path}/missing')),
          throwsA(isA<FileSystemException>()));
      await target.delete(); // No worker keeps an output handle alive.
    } finally {
      await directory.delete(recursive: true);
    }
  });
  for (final fail in [false, true]) {
    test(
        'real mid-copy ${fail ? 'read exception' : 'source mutation'} fails closed and closes output',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('identity_midcopy_');
      final source = File('${directory.path}/identity.sqlite');
      final factory =
          createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
      final db = await factory.openDatabase(source.path);
      await db.execute('CREATE TABLE box_client (k TEXT PRIMARY KEY, v TEXT)');
      await db.insert('box_client', {'k': 'user_id', 'v': '@fixture:test'});
      await db.execute('CREATE TABLE retained (payload BLOB)');
      await db.execute('INSERT INTO retained VALUES (zeroblob(524288))');
      await db.close();
      final original = await source.readAsBytes();
      final io = _MidCopyIo(source.path, fail);
      try {
        await expectLater(
            ReadOnlySqlCipherIdentityReader(io: io).read(source.path, ''),
            throwsA(anything));
        expect(io.injected, isTrue);
        // On Windows an open output handle would also prevent this cleanup.
        expect(await Directory(io.snapshotDirectory!).exists(), isFalse);
        if (fail) expect(await source.readAsBytes(), original);
      } finally {
        await directory.delete(recursive: true);
      }
    });
  }
  test('copy hash and two verification reads use three bounded passes',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('identity_io_test_');
    try {
      final source = File('${directory.path}/source');
      final target = File('${directory.path}/snapshot');
      final chunk = List<int>.generate(65536, (i) => i % 251);
      final sink = source.openWrite();
      for (var i = 0; i < 64; i++) {
        sink.add(chunk);
        await sink.flush();
      }
      await sink.close();
      final io = _MeteredIo();
      final original = await sha256.bind(source.openRead()).first;
      final hash = await io.copyAndHash(_StreamOnlyFile(source), target);
      expect(hash, original.toString());
      expect(await io.digest(target), hash);
      expect(await io.digest(source), hash);
      expect(io.reads, 3);
      expect(io.bytes, 3 * 64 * chunk.length);
      expect(io.maxChunk, lessThanOrEqualTo(65536));
    } finally {
      await directory.delete(recursive: true);
    }
  });

  for (final mutation in [
    'source-truncate',
    'snapshot-corrupt',
    'wal-add',
    'shm-add',
    'sidecar-directory',
    'copy-write-failure',
    'wal-remove',
    'shm-remove',
    'source-link-replacement'
  ]) {
    test('identity snapshot rejects $mutation and removes temporary copy',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('identity_probe_test_');
      final source = File('${directory.path}/identity.sqlite');
      final factory =
          createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
      final db = await factory.openDatabase(source.path);
      await db.execute('CREATE TABLE box_client (k TEXT PRIMARY KEY, v TEXT)');
      await db.insert('box_client', {'k': 'user_id', 'v': '@fixture:test'});
      await db.close();
      final original = await source.readAsBytes();
      if (mutation == 'wal-remove') {
        await File('${source.path}-wal').writeAsBytes([]);
      }
      if (mutation == 'shm-remove') {
        await File('${source.path}-shm').writeAsBytes([]);
      }
      final io = _AdversarialIo()
        ..afterCopy = (file, target) async {
          switch (mutation) {
            case 'source-truncate':
              await file.writeAsBytes([1, 2, 3]);
            case 'snapshot-corrupt':
              await target.writeAsBytes([1, 2, 3]);
            case 'wal-add':
              break;
            case 'shm-add':
              break;
            case 'sidecar-directory':
              await Directory('${source.path}-wal').create();
            case 'copy-write-failure':
              throw const FileSystemException('fixture failure');
            case 'wal-remove':
              break;
            case 'shm-remove':
              break;
            case 'source-link-replacement':
              break;
          }
        };
      io.beforeDigest = (file) async {
        if (file.path == source.path && mutation == 'wal-add') {
          await File('${source.path}-wal').writeAsBytes([1]);
        }
        if (file.path == source.path && mutation == 'shm-add') {
          await File('${source.path}-shm').writeAsBytes([1]);
        }
        if (file.path == source.path && mutation == 'wal-remove') {
          await File('${source.path}-wal').delete();
        }
        if (file.path == source.path && mutation == 'shm-remove') {
          await File('${source.path}-shm').delete();
        }
        // Replace a sidecar with a symlink after its original absence was
        // captured. A link to identical bytes is still an invalid file type.
        if (file.path == source.path && mutation == 'source-link-replacement') {
          await Link('${source.path}-wal').create(source.path);
        }
      };
      try {
        await expectLater(
            ReadOnlySqlCipherIdentityReader(io: io).read(source.path, ''),
            throwsA(anything));
        expect(await Directory(io.snapshotDirectory!).exists(), isFalse);
        if (mutation != 'source-truncate') {
          expect(await source.readAsBytes(), original);
        }
      } finally {
        await directory.delete(recursive: true);
      }
    });
  }

  test('snapshot DB query failure cleans up without modifying source',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('identity_bad_test_');
    final source = File('${directory.path}/bad.sqlite');
    await source.writeAsBytes(List.filled(1000, 7));
    final original = await source.readAsBytes();
    final io = _AdversarialIo();
    try {
      await expectLater(
          ReadOnlySqlCipherIdentityReader(io: io).read(source.path, 'fixture'),
          throwsA(anything));
      expect(await source.readAsBytes(), original);
      expect(await Directory(io.snapshotDirectory!).exists(), isFalse);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
