import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_image_preview.dart';

void main() {
  test('thumbnail failure falls back to original', () async {
    final original = Uint8List.fromList([1, 2, 3]);
    expect(
        await loadChatImagePreview(
            animated: false,
            loadThumbnail: () async => throw StateError('unavailable'),
            loadOriginal: () async => original),
        same(original));
  });
  test('static preview does not eagerly load original', () async {
    final thumbnail = Uint8List.fromList([1, 2]);
    final result = await loadChatImagePreview(
        animated: false,
        loadThumbnail: () async => thumbnail,
        loadOriginal: () async => throw StateError('must not fetch original'));
    expect(identical(result, thumbnail), isTrue);
  });
  test('GIF skips static thumbnail; old images without thumbnails fall back',
      () async {
    final original = Uint8List.fromList([1, 2, 3]);
    expect(
        await loadChatImagePreview(
            animated: true,
            loadThumbnail: () async => throw StateError('static thumbnail'),
            loadOriginal: () async => original),
        same(original));
    expect(
        await loadChatImagePreview(
            animated: false,
            loadThumbnail: () async => null,
            loadOriginal: () async => original),
        same(original));
  });
}
