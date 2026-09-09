import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:matrix/matrix.dart';
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
      expect(
          await scratch
              .list(recursive: true)
              .where((entry) =>
                  entry is File &&
                  !entry.path.endsWith('.len') &&
                  !entry.path.endsWith('.ref'))
              .length,
          1);
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
      expect(
          await scratch
              .list(recursive: true)
              .where((entry) => entry is File)
              .length,
          0);
    });
  }
}
