import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_thumbnail.dart';
import 'package:liuhetong_mobile/features/matrix/gif_image_policy.dart';

void main() {
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
