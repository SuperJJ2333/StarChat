import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_thumbnail.dart';
import 'package:liuhetong_mobile/features/matrix/gif_image_policy.dart';

void main() {
  Uint8List animation({int frames = 1, int width = 1, int height = 1}) =>
      Uint8List.fromList([
        71,
        73,
        70,
        56,
        57,
        97,
        width & 255,
        width >> 8,
        height & 255,
        height >> 8,
        0,
        0,
        0,
        for (var i = 0; i < frames; i++) ...[
          44,
          0,
          0,
          0,
          0,
          1,
          0,
          1,
          0,
          0,
          2,
          2,
          68,
          1,
          0
        ],
        59
      ]);
  test(
      'full GIF send validation rejects truncated later frames and missing trailer',
      () {
    final valid = animation(frames: 2);
    expect(() => validateGifStructureForSend(valid), returnsNormally);
    expect(
        () => validateGifStructureForSend(
            Uint8List.sublistView(valid, 0, valid.length - 3)),
        throwsFormatException);
    expect(
        () => validateGifStructureForSend(
            Uint8List.sublistView(valid, 0, valid.length - 1)),
        throwsFormatException);
  });
  test(
      'decoded budget counts full logical canvas for optimized frame rectangles',
      () {
    expect(
        () => validateGifStructureForSend(
            animation(frames: 32, width: 2048, height: 2048)),
        returnsNormally);
    expect(
        () => validateGifStructureForSend(
            animation(frames: 33, width: 2048, height: 2048)),
        throwsFormatException);
  });
  test('GIF frame rectangle must fit logical canvas', () {
    final invalid = animation();
    invalid[18] = 2;
    expect(() => validateGifStructureForSend(invalid), throwsFormatException);
  });
  test('GIF trailing payload rejected consistently with business upload', () {
    expect(
        () => validateGifStructureForSend(Uint8List.fromList([
              ...animation(),
              1,
              2,
              3,
            ])),
        throwsFormatException);
  });
  test('GIF header dimensions are available without pixel decoding', () async {
    final header = Uint8List.fromList([71, 73, 70, 56, 57, 97, 0, 4, 0, 2]);
    expect(gifDimensions(header), (1024, 512));
    expect(await decodeImageDimensions(header), (1024, 512));
  });
  test('native static compressor must never receive GIF bytes', () async {
    final header = Uint8List.fromList([71, 73, 70, 56, 57, 97, 1, 0, 1, 0]);
    expect(isGifBytes(header), isTrue);
    expect(await buildChatImageThumbnail(header), isNull);
  });
  test('oversized GIF is rejected before allocating image frames', () {
    final header =
        Uint8List.fromList([71, 73, 70, 56, 57, 97, 255, 255, 255, 255]);
    expect(() => validateGifForSend(header), throwsFormatException);
    expect(
        () => validateGifForSend(
            Uint8List.fromList([71, 73, 70, 56, 57, 97, 1, 0, 1, 0])),
        returnsNormally);
  });
}
