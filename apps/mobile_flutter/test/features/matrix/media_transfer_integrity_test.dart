import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

final class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final Directory root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root.path;
}

// Exercise the shipped SDK AES-CTR/SHA-256 implementation, never a substitute
// cipher. Copying ciphertext models a transport boundary; no server or Matrix
// room-key exchange is claimed. Native video decoding has separate iOS tests.
EncryptedFile _received(EncryptedFile sent, Uint8List body) => EncryptedFile(
      data: Uint8List.fromList(body),
      k: sent.k,
      iv: sent.iv,
      sha256: sent.sha256,
    );

void main() {
  late Directory scratch;
  late PathProviderPlatform oldPaths;
  setUp(() async {
    oldPaths = PathProviderPlatform.instance;
    final root =
        Directory('../../docs/verification/artifacts/2026-09-09/mobile-parity');
    await root.create(recursive: true);
    scratch = await Directory(await root.resolveSymbolicLinks())
        .createTemp('media-transfer-');
    PathProviderPlatform.instance = _Paths(scratch);
  });
  tearDown(() async {
    PathProviderPlatform.instance = oldPaths;
    await scratch.delete(recursive: true);
  });

  for (final name in ['video-h264.mp4', 'video-hevc.mp4']) {
    test('SDK encrypted $name transport resolves exact bytes to one MP4 cache',
        () async {
      final original = await File('assets/diagnostics/$name').readAsBytes();
      final sent = await MatrixFile(bytes: original, name: name).encrypt();
      expect(sent.data, isNot(orderedEquals(original)),
          reason: 'Transport payload must be ciphertext');
      final received = _received(sent, sent.data);
      final key =
          MediaCacheKey(roomId: '!synthetic:example.test', eventId: name);
      var receives = 0;
      final file = await resolveCachedVideoFile(
        key: key,
        memoryCache: MediaMemoryCache(),
        decrypt: () async {
          receives++;
          final clear = await NativeImplementations.dummy.decryptFile(received);
          if (clear == null) throw StateError('Synthetic attachment rejected');
          return clear;
        },
      );
      expect(await file.readAsBytes(), orderedEquals(original));
      expect(file.path, endsWith('.mp4'));
      expect(await MediaCache.totalCachedBytes(), original.length);
      final again = await resolveCachedVideoFile(
        key: key,
        memoryCache: MediaMemoryCache(),
        decrypt: () async => throw StateError('Disk cache must avoid transfer'),
      );
      expect(again.path, file.path);
      expect(receives, 1);
      await _expectCacheFiles(scratch, key, original);
    });
  }

  for (final corruption in ['bit-flip', 'truncation']) {
    test('SDK rejects $corruption ciphertext before plaintext caching',
        () async {
      final original =
          await File('assets/diagnostics/video-h264.mp4').readAsBytes();
      final sent =
          await MatrixFile(bytes: original, name: 'video.mp4').encrypt();
      final damaged = Uint8List.fromList(corruption == 'truncation'
          ? sent.data.sublist(0, sent.data.length - 1)
          : sent.data);
      if (corruption == 'bit-flip') damaged[damaged.length ~/ 2] ^= 1;
      final received = _received(sent, damaged);
      expect(await NativeImplementations.dummy.decryptFile(received), isNull);
      final key =
          MediaCacheKey(roomId: '!synthetic:example.test', eventId: corruption);
      await expectLater(
          resolveCachedVideoFile(
            key: key,
            memoryCache: MediaMemoryCache(),
            decrypt: () async {
              final clear =
                  await NativeImplementations.dummy.decryptFile(received);
              if (clear == null) {
                throw StateError('Synthetic attachment rejected');
              }
              return clear;
            },
          ),
          throwsStateError);
      expect(await MediaCache.cached(key.roomId, key.eventId), isNull);
      expect(await MediaCache.totalCachedBytes(), 0);
      await _expectCacheFiles(scratch, key, null);
    });
  }
}

Future<void> _expectCacheFiles(
    Directory root, MediaCacheKey key, Uint8List? plaintext) async {
  final accountRoot =
      'chat-media/v2/${sha256.convert(utf8.encode(key.accountId))}';
  final expected = <String>['chat-media/quota-v1.sqlite'];
  if (plaintext != null) {
    final object = '$accountRoot/objects/${sha256.convert(plaintext)}.mp4';
    final reference = sha256.convert(utf8.encode(jsonEncode([
      key.roomId,
      key.eventId,
    ])));
    expected
        .addAll([object, '$object.len', '$accountRoot/refs/$reference.ref']);
  }
  final actual = await root
      .list(recursive: true, followLinks: false)
      .where((entry) => entry is! Directory)
      .map(
          (entry) => p.split(p.relative(entry.path, from: root.path)).join('/'))
      .toList();
  expect(actual, unorderedEquals(expected),
      reason: 'Only the quota index and the exact authorized content object, '
          'integrity sidecar and message reference may remain');
}
