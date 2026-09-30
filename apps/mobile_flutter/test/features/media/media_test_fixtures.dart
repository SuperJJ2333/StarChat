import 'dart:typed_data';
import 'dart:math';
import 'package:image/image.dart' as img;

Uint8List mediaTestPng({int width = 2, int height = 3}) =>
    img.encodePng(img.Image(width: width, height: height));

/// Real high-entropy indexed pixels: compression size comes from image data.
Uint8List largeMediaTestGif(
    {int? repeat = 3, int frames = 8, bool disposalScenes = false}) {
  final encoder = img.GifEncoder(repeat: repeat ?? 0, dispose: 2);
  final random = Random(761);
  for (var frame = 0; frame < frames; frame++) {
    final image =
        img.Image(width: 384, height: 384, numChannels: 4, withPalette: true);
    for (var color = 0; color < 256; color++) {
      image.palette!.setRgba(color, color, (color * 31) % 256,
          (color * 67) % 256, color == 0 ? 0 : 255);
    }
    if (disposalScenes) {
      image.palette!.setRgba(1, 255, 0, 0, 255);
      image.palette!.setRgba(2, 0, 255, 0, 255);
      image.palette!.setRgba(3, 0, 0, 255, 255);
    }
    for (final pixel in image) {
      pixel.index = pixel.x < 24 && pixel.y < 24 ? 0 : 1 + random.nextInt(255);
      if (disposalScenes && pixel.x < 180 && pixel.y < 180) {
        pixel.index = 0;
        final left = frame.isEven ? 40 : 100;
        if (pixel.x >= left &&
            pixel.x < left + 40 &&
            pixel.y >= 40 &&
            pixel.y < 80) {
          pixel.index = 1 + frame % 3;
        }
      }
    }
    encoder.addFrame(image, duration: 7 + frame);
  }
  final bytes = encoder.finish()!;
  if (disposalScenes) {
    var offset = 13;
    var frame = 0;
    while (bytes[offset] != 59) {
      final marker = bytes[offset++];
      if (marker == 33) {
        final label = bytes[offset++];
        if (label == 249) {
          bytes[offset + 1] =
              (bytes[offset + 1] & ~28) | ([1, 3, 2][frame++ % 3] << 2);
        }
      } else {
        final packed = bytes[offset + 8];
        offset += 9;
        if (packed & 128 != 0) offset += 3 * (1 << ((packed & 7) + 1));
        offset++;
      }
      while (bytes[offset] != 0) {
        offset += bytes[offset] + 1;
      }
      offset++;
    }
  }
  // GifEncoder always emits its 19-byte loop extension at byte 13.
  return repeat == null
      ? Uint8List.fromList([...bytes.sublist(0, 13), ...bytes.sublist(32)])
      : bytes;
}

/// Two 1x1 GIF frames with a global two-color palette and valid LZW data.
Uint8List mediaTestGif({int frames = 2, int width = 1, int height = 1}) =>
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
      128,
      0,
      0,
      0,
      0,
      0,
      255,
      255,
      255,
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
        0,
      ],
      59,
    ]);
