import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/moments/moment_image_preprocessor.dart';

/// 最小合法 1×1 PNG，供解码器使用。
Uint8List pngBytes() => Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00,
  0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01,
  0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F,
  0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00,
  0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  test('target dimensions cap the longest edge proportionally', () {
    final landscape = targetDimensions(4032, 3024, 1080);
    expect(landscape.width, 1080);
    expect(landscape.height, 810);

    final portrait = targetDimensions(3024, 4032, 1080);
    expect(portrait.width, 810);
    expect(portrait.height, 1080);

    final small = targetDimensions(800, 600, 1080);
    expect(small.width, 800);
    expect(small.height, 600, reason: '小图不放大');
  });

  test('compresses with descending quality until under 500KB', () async {
    final qualities = <int>[];
    final preprocessor = MomentImagePreprocessor(
      compressBytes: (bytes, {required minWidth, required minHeight, required quality}) async {
        qualities.add(quality);
        // 第一档 85 仍超限，第二档 70 达标。
        return Uint8List(quality >= 85 ? maxMomentImageBytes + 1 : 1024);
      },
    );

    final output = await preprocessor.process(pngBytes());

    expect(qualities, [85, 70]);
    expect(output.lengthInBytes, 1024);
  });

  test('compressor failure raises a user-facing exception, never crashes',
      () async {
    final preprocessor = MomentImagePreprocessor(
      compressBytes: (bytes, {required minWidth, required minHeight, required quality}) async {
        throw const FormatException('unsupported');
      },
    );

    await expectLater(
      preprocessor.process(pngBytes()),
      throwsA(isA<MomentImageException>()),
    );
  });

  test('always-normalizing pipeline converts any image to compressed JPEG',
      () async {
    var capturedWidth = 0;
    var capturedHeight = 0;
    final preprocessor = MomentImagePreprocessor(
      compressBytes: (bytes, {required minWidth, required minHeight, required quality}) async {
        capturedWidth = minWidth;
        capturedHeight = minHeight;
        return Uint8List.fromList([9]);
      },
    );

    final output = await preprocessor.process(pngBytes());
    expect(output, Uint8List.fromList([9]));
    expect(capturedWidth, greaterThan(0));
    expect(capturedHeight, greaterThan(0));
  });

  test('corrupt image bytes raise a friendly exception', () async {
    final preprocessor = MomentImagePreprocessor(
      compressBytes: (bytes, {required minWidth, required minHeight, required quality}) async =>
          Uint8List.fromList([1]),
    );

    await expectLater(
      preprocessor.process(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<MomentImageException>()),
    );
  });
}
