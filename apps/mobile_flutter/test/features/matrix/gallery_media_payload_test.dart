import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/device_gallery_source.dart';
import 'package:liuhetong_mobile/features/matrix/gallery_media_payload.dart';

void main() {
  test('original images above 20MiB are rejected before reading bytes',
      () async {
    var read = false;
    final photo = GalleryPhoto(
        id: 'large',
        thumbnail: Uint8List(0),
        originalSizeBytes: () async => maxGalleryImageBytes + 1,
        originalBytes: () async {
          read = true;
          return Uint8List(0);
        },
        compressedBytes: () async => Uint8List(0));
    await expectLater(
        prepareGalleryMedia(photo, original: true), throwsFormatException);
    expect(read, false);
  });
  test('compressed image enforces same byte limit and rejects empty input',
      () async {
    var bytes = Uint8List(maxGalleryImageBytes + 1);
    final photo = GalleryPhoto(
        id: 'large',
        thumbnail: Uint8List(0),
        originalBytes: () async => bytes,
        compressedBytes: () async => bytes);
    await expectLater(
        prepareGalleryMedia(photo, original: false), throwsFormatException);
    bytes = Uint8List(0);
    await expectLater(
        prepareGalleryMedia(photo, original: false), throwsFormatException);
  });
  test('shared gallery preparation preserves GIF and honors original selection',
      () async {
    final gif = base64Decode(
        'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7');
    var compressed = 0;
    var original = 0;
    final photo = GalleryPhoto(
        id: 'one',
        thumbnail: Uint8List(0),
        mimeType: 'image/jpeg',
        compressedBytes: () async {
          compressed++;
          return gif;
        },
        originalBytes: () async {
          original++;
          return gif;
        });
    final result = await prepareGalleryMedia(photo, original: false);
    expect(result.bytes, same(gif));
    expect(result.mimeType, 'image/gif');
    expect(result.fileName, endsWith('.gif'));
    expect(compressed, 1);
    expect(original, 0);
    await prepareGalleryMedia(photo, original: true);
    expect(original, 1);
  });
  test('shared GIF limit rejects oversized canvas', () async {
    final gif = Uint8List.fromList(
        [71, 73, 70, 56, 57, 97, 255, 255, 255, 255, 0, 0, 0]);
    final photo = GalleryPhoto(
        id: 'bad',
        thumbnail: Uint8List(0),
        compressedBytes: () async => gif,
        originalBytes: () async => gif);
    await expectLater(
        prepareGalleryMedia(photo, original: false), throwsFormatException);
  });
}
