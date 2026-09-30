import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/device_gallery_source.dart';
import 'package:liuhetong_mobile/features/matrix/gallery_media_payload.dart';
import '../media/media_test_fixtures.dart';

void main() {
  test('default gallery reselect reuses compliant canonical static bytes',
      () async {
    final canonical = mediaTestPng();
    var compressedCalls = 0;
    var originalCalls = 0;
    final photo = GalleryPhoto(
      id: 'saved-image',
      thumbnail: canonical,
      mimeType: 'image/png',
      originalSizeBytes: () async => canonical.length,
      originalBytes: () async {
        originalCalls++;
        return canonical;
      },
      compressedBytes: () async {
        compressedCalls++;
        return mediaTestPng(width: 1, height: 1);
      },
    );
    final prepared = await prepareGalleryMedia(photo, original: false);
    expect(prepared.bytes, same(canonical));
    expect(prepared.mimeType, 'image/png');
    expect(originalCalls, 1);
    expect(compressedCalls, 0);
  });
  for (final original in [false, true]) {
    for (final size in [
      20 * 1024 * 1024 - 1,
      20 * 1024 * 1024,
      20 * 1024 * 1024 + 1
    ]) {
      test(
          'group video ignores original size $size original=$original and compresses',
          () async {
        var reads = 0;
        Future<Uint8List> read() async {
          reads++;
          return Uint8List.fromList([1]);
        }

        final photo = GalleryPhoto(
            id: 'video',
            thumbnail: Uint8List(0),
            isVideo: true,
            mimeType: 'video/mp4',
            originalSizeBytes: () async => size,
            originalBytes: read,
            compressedBytes: read);
        final send = Function.apply(prepareGalleryMedia, [
          photo
        ], {
          #original: original,
          #isGroup: true
        }) as Future<GalleryMediaPayload>;
        final payload = await send;
        expect(reads, 1);
        expect(payload.mimeType, 'video/mp4');
      });
    }
  }

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
  test(
      'shared gallery preparation preserves GIF source in both selection modes',
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
    expect(compressed, 0);
    expect(original, 1);
    await prepareGalleryMedia(photo, original: true);
    expect(original, 2);
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
