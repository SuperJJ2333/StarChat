import 'dart:typed_data';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/media/media_asset_gateway.dart';

import 'media_test_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'retained file reads reject missing or empty files and recheck authority',
      () async {
    final directory = Directory(
        '../../docs/verification/artifacts/2026-10-01/unified-media/read-file-fixtures');
    await directory.create(recursive: true);
    final scratch = await directory.createTemp('case-');
    addTearDown(() => scratch.delete(recursive: true));
    final file = File('${scratch.path}/retained.gif');
    await expectLater(
        MediaAssetGateway.readFile(() async => file), throwsFormatException);
    await file.writeAsBytes([]);
    await expectLater(
        MediaAssetGateway.readFile(() async => file), throwsFormatException);
    await file.writeAsBytes([1, 2, 3]);
    var checks = 0;
    expect(
        await MediaAssetGateway.readFile(() async => file,
            ensureCurrent: () => checks++),
        same(file));
    expect(checks, 3);
    var active = true;
    await expectLater(
        MediaAssetGateway.readFile(() async {
          active = false;
          return file;
        }, ensureCurrent: () {
          if (!active) throw StateError('revoked');
        }),
        throwsStateError);
  });
  test('large real animated GIF is compressed below the unified byte budget',
      () async {
    final bytes = largeMediaTestGif();
    expect(bytes.length, greaterThan(500 * 1024));
    final result = await MediaAssetGateway.prepareImage(bytes,
        transform: (_) => throw StateError('GIF must not flatten'));
    expect(result.length, lessThanOrEqualTo(500 * 1024));
    expect(
        await MediaAssetGateway.prepareImage(result,
            transform: (_) => throw StateError('must reuse GIF')),
        same(result));
  });
  test('an explicit static transform cannot escape the unified byte budget',
      () async {
    await expectLater(
        MediaAssetGateway.prepareImage(Uint8List.fromList([255, 216, 255]),
            transform: (_) async => Uint8List(500 * 1024 + 1)),
        throwsFormatException);
  });
  test('disguised GIF keeps original bytes and truthful MIME and filename',
      () async {
    final bytes = mediaTestGif();
    final asset = await MediaAssetGateway.inspect(bytes,
        mimeType: 'image/jpeg', filename: 'animation.jpg');
    expect(asset.bytes, same(bytes));
    expect(asset.isGif, isTrue);
    expect(asset.mimeType, 'image/gif');
    expect(asset.filename, 'animation.gif');
  });

  test('GIF original processing never calls a static transform', () async {
    final bytes = mediaTestGif();
    var transforms = 0;
    final result =
        await MediaAssetGateway.prepareImage(bytes, transform: (_) async {
      transforms++;
      return Uint8List.fromList([255, 216, 255]);
    });
    expect(result, same(bytes));
    expect(transforms, 0);
  });

  test('truncated later GIF frame rejects before processing', () async {
    final bytes = mediaTestGif();
    final truncated = Uint8List.sublistView(bytes, 0, bytes.length - 3);
    await expectLater(
        MediaAssetGateway.inspect(truncated,
            mimeType: 'image/jpeg', filename: 'broken.jpg'),
        throwsFormatException);
    var transforms = 0;
    await expectLater(
        MediaAssetGateway.prepareImage(truncated, transform: (value) async {
          transforms++;
          return value;
        }),
        throwsFormatException);
    expect(transforms, 0);
  });

  test('GIF canvas and cumulative decoded limits reject before transforms',
      () async {
    for (final bytes in [
      mediaTestGif(width: 2049, height: 2048),
      mediaTestGif(frames: 33, width: 2048, height: 2048)
    ]) {
      await expectLater(
          MediaAssetGateway.prepareImage(bytes,
              transform: (_) => throw StateError('must not transform')),
          throwsFormatException);
    }
  });

  test('static image processing returns the derived content', () async {
    final bytes = Uint8List.fromList([255, 216, 255, 0]);
    final derived = Uint8List.fromList([255, 216, 255, 1]);
    var transforms = 0;
    final result =
        await MediaAssetGateway.prepareImage(bytes, transform: (input) async {
      expect(input, same(bytes));
      transforms++;
      return derived;
    });
    expect(result, same(derived));
    expect(transforms, 1);
  });

  test('trusted original digest mismatch rejects without caching or retry',
      () async {
    final bytes = mediaTestGif();
    var loads = 0;
    Future<Uint8List> load() async {
      loads++;
      return bytes;
    }

    await expectLater(
        MediaAssetGateway.readOriginal(load, expectedSha256: '0' * 64),
        throwsFormatException);
    expect(loads, 1);
    expect(
        await MediaAssetGateway.readOriginal(load,
            expectedSha256: sha256.convert(bytes).toString()),
        same(bytes));
    expect(loads, 2);
  });

  test('loader authorization failures propagate without fallback', () async {
    final error = StateError('account revoked');
    await expectLater(MediaAssetGateway.readOriginal(() => throw error),
        throwsA(same(error)));
  });

  test('export filenames follow detected bytes and preserve unknown originals',
      () {
    expect(
        MediaAssetGateway.exportFilename(mediaTestGif(),
            filename: 'favorite.jpg'),
        'favorite.gif');
    expect(
        MediaAssetGateway.exportFilename(
            Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
            filename: 'a.jpeg'),
        'a.png');
    expect(
        MediaAssetGateway.exportFilename(Uint8List.fromList([255, 216, 255]),
            filename: 'a.png'),
        'a.jpg');
    expect(
        MediaAssetGateway.exportFilename(
            Uint8List.fromList([82, 73, 70, 70, 0, 0, 0, 0, 87, 69, 66, 80]),
            filename: 'a.jpg'),
        'a.webp');
    expect(
        MediaAssetGateway.exportFilename(Uint8List.fromList([1, 2, 3]),
            filename: 'voice.ogg'),
        'voice.ogg');
  });
}
