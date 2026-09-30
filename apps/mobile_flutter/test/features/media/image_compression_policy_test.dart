import 'dart:math';
import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:liuhetong_mobile/features/media/image_compression_policy.dart';
import 'package:liuhetong_mobile/features/matrix/gif_image_policy.dart';
import 'media_test_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native composited appearance survives disposal 1, 2 and 3', () async {
    final original = largeMediaTestGif(disposalScenes: true);
    expect(original.length, greaterThan(maxUnifiedImageBytes));
    final result = await ImageCompressionPolicy.prepare(original);
    final sourceCodec = await ui.instantiateImageCodec(original);
    final resultCodec = await ui.instantiateImageCodec(result);
    try {
      for (var index = 0; index < sourceCodec.frameCount; index++) {
        final source = await sourceCodec.getNextFrame();
        final target = await resultCodec.getNextFrame();
        try {
          final sourceData = (await source.image
              .toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
          final targetData = (await target.image
              .toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
          for (final location in [(4, 4), (60, 60), (120, 60), (60, 120)]) {
            final sourceOffset =
                (location.$2 * source.image.width + location.$1) * 4;
            final targetX =
                location.$1 * target.image.width ~/ source.image.width;
            final targetY =
                location.$2 * target.image.height ~/ source.image.height;
            final targetOffset = (targetY * target.image.width + targetX) * 4;
            for (var channel = 0; channel < 4; channel++) {
              expect(targetData.getUint8(targetOffset + channel),
                  sourceData.getUint8(sourceOffset + channel),
                  reason: 'frame $index location $location channel $channel');
            }
          }
        } finally {
          source.image.dispose();
          target.image.dispose();
        }
      }
    } finally {
      sourceCodec.dispose();
      resultCodec.dispose();
    }
  });
  for (final repeat in <int?>[0, 3, null]) {
    test('real GIF preserves frames, exact delays, alpha and loop $repeat',
        () async {
      final original = largeMediaTestGif(repeat: repeat);
      final result = await ImageCompressionPolicy.prepare(original);
      final evidence = Directory(
          '../../docs/verification/artifacts/2026-10-01/unified-media/gif-budget-results');
      await evidence.create(recursive: true);
      await File('${evidence.path}/input-loop-$repeat.gif')
          .writeAsBytes(original);
      await File('${evidence.path}/output-loop-$repeat.gif')
          .writeAsBytes(result);
      expect(result.length, lessThanOrEqualTo(maxUnifiedImageBytes));
      validateGifStructureForSend(result);
      final decoded = img.decodeGif(result)!;
      expect(decoded.numFrames, 8);
      expect(decoded.frames.map((frame) => frame.frameDuration),
          List.generate(8, (index) => (7 + index) * 10));
      expect(decoded.loopCount, repeat ?? 0);
      expect(
          String.fromCharCodes(result).contains('NETSCAPE2.0'), repeat != null);
      for (final frame in decoded.frames) {
        expect(frame.getPixel(2, 2).a, 0);
        expect(frame.getPixel(frame.width ~/ 2, frame.height ~/ 2).a, 255);
      }
      expect(await ImageCompressionPolicy.prepare(result), same(result));
    });
  }
  test('excessive working frame count rejects before codec allocation',
      () async {
    await expectLater(ImageCompressionPolicy.prepare(mediaTestGif(frames: 257)),
        throwsFormatException);
  });
  test('large static PNG has bounded output dimensions and reuses exact result',
      () async {
    final random = Random(54);
    final image = img.Image(width: 1200, height: 800);
    for (final pixel in image) {
      pixel.setRgb(
          random.nextInt(256), random.nextInt(256), random.nextInt(256));
    }
    final original = img.encodePng(image);
    expect(original.length, greaterThan(maxUnifiedImageBytes));
    final result = await ImageCompressionPolicy.prepare(original);
    final decoded = img.decodeImage(result)!;
    expect(result.length, lessThanOrEqualTo(maxUnifiedImageBytes));
    expect(max(decoded.width, decoded.height),
        lessThanOrEqualTo(maxUnifiedImageEdge));
    expect(await ImageCompressionPolicy.prepare(result), same(result));
  });
  test('small real PNG and JPEG preserve exact source bytes', () async {
    for (final bytes in [
      mediaTestPng(),
      img.encodeJpg(img.Image(width: 10, height: 8))
    ]) {
      expect(await ImageCompressionPolicy.prepare(bytes), same(bytes));
    }
  });
  test('corrupt GIF fails before static transform or encoder', () async {
    final bytes = largeMediaTestGif();
    await expectLater(
        ImageCompressionPolicy.prepare(
            Uint8List.sublistView(bytes, 0, bytes.length - 1),
            transform: (_) => throw StateError('not called')),
        throwsFormatException);
  });
}
