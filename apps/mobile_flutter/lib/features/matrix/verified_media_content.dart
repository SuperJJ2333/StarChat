import 'dart:typed_data';
import 'dart:isolate';
import 'media_transfer_budget.dart';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show compute, visibleForTesting;

/// Observes actual full plaintext digest work, never content or digest values.
@visibleForTesting
void Function(int byteLength, bool worker)? mediaDigestObserver;

String digestMediaBytes(Uint8List bytes) {
  final digest = crypto.sha256.convert(bytes).toString();
  mediaDigestObserver?.call(bytes.length, false);
  return digest;
}

/// A proof of one owned immutable snapshot, never a caller-supplied hash.
/// The private constructor and registry prevent trusting mutable aliases or a
/// digest asserted by an external loader. Scope includes the account epoch.
final class VerifiedMediaContent {
  VerifiedMediaContent._(this.bytes, this.digest, this.scope);

  final Uint8List bytes;
  final String digest;
  final Object scope;
  static final _proofs = Expando<VerifiedMediaContent>();
  static final _hash = RegExp(r'^[a-f0-9]{64}$');

  static VerifiedMediaContent? lookup(Uint8List bytes, Object scope,
      {String? expectedSha256}) {
    final proof = _proofs[bytes];
    if (proof == null || proof.scope != scope) return null;
    proof._check(expectedSha256);
    return proof;
  }

  static Future<VerifiedMediaContent> verify(Uint8List bytes,
      {required Object scope, String? expectedSha256}) async {
    if (expectedSha256 != null && !_hash.hasMatch(expectedSha256)) {
      throw const FormatException('Invalid media content digest');
    }
    final known = lookup(bytes, scope, expectedSha256: expectedSha256);
    if (known != null) return known;
    // compute snapshots the input into the worker isolate. Return that exact
    // snapshot, not the caller's possibly mutated source after the await.
    final result = await sharedMediaTransferBudget.run(
        MediaTransferPlan.upload(bytes.length),
        () => compute(_verify, (bytes, Isolate.current.hashCode)));
    mediaDigestObserver?.call(result.$1.length, result.$3);
    final proof = VerifiedMediaContent._(
        result.$1.asUnmodifiableView(), result.$2, scope);
    proof._check(expectedSha256);
    _proofs[proof.bytes] = proof;
    return proof;
  }

  void _check(String? expected) {
    if (expected != null && expected != digest) {
      throw const FormatException('Media content digest mismatch');
    }
  }

  static (Uint8List, String, bool) _verify((Uint8List, int) input) => (
        input.$1,
        crypto.sha256.convert(input.$1).toString(),
        Isolate.current.hashCode != input.$2
      );
}
