import 'dart:io';

import 'package:crypto/crypto.dart';

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
