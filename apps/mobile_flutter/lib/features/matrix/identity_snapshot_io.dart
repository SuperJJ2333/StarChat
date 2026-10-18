import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// The worker receives file paths only. Identity SQL and cipher stay in the
/// reader; each await joins the worker before verification or temp cleanup.
final class OffloadedIdentitySnapshotIo extends IdentitySnapshotIo {
  const OffloadedIdentitySnapshotIo({this.onWorkerCompleted});

  @visibleForTesting
  final void Function(String?)? onWorkerCompleted;

  @override
  Future<String> copyAndHash(File source, File destination) {
    final paths = (source.path, destination.path);
    return _join(Isolate.run(() => _copyIdentitySnapshot(paths),
        debugName: 'matrix-identity-copy'));
  }

  @override
  Future<String> digest(File file) {
    final path = file.path;
    return _join(Isolate.run(() => _digestIdentitySnapshot(path),
        debugName: 'matrix-identity-hash'));
  }

  Future<String> _join(Future<(String, String?)> work) async {
    final result = await work;
    try {
      onWorkerCompleted?.call(result.$2);
    } catch (_) {
      // Observing worker identity cannot change a verification result.
    }
    return result.$1;
  }
}

Future<(String, String?)> _copyIdentitySnapshot((String, String) paths) async =>
    (
      await const IdentitySnapshotIo()
          .copyAndHash(File(paths.$1), File(paths.$2)),
      Isolate.current.debugName
    );

Future<(String, String?)> _digestIdentitySnapshot(String path) async => (
      await const IdentitySnapshotIo().digest(File(path)),
      Isolate.current.debugName
    );

/// Bounded streaming I/O; identity checking still verifies both copies later.
class IdentitySnapshotIo {
  const IdentitySnapshotIo();

  Stream<List<int>> read(File file) => file.openRead();

  Future<String> digest(File file) async =>
      (await sha256.bind(read(file)).first).toString();

  Future<String> copyAndHash(File source, File destination) async {
    final result = _DigestResult();
    final hash = sha256.startChunkedConversion(result);
    final output = destination.openWrite();
    try {
      await output.addStream(read(source).map((chunk) {
        hash.add(chunk);
        return chunk;
      }));
    } finally {
      await output.close();
      hash.close();
    }
    return result.value!.toString();
  }
}

class _DigestResult implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
