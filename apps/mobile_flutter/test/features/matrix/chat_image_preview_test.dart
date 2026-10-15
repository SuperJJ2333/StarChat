import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_image_preview.dart';
import '../media/media_test_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('GIF bubble prefers static thumbnail without reading original',
      () async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff112233), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(4, 4);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    final preview = await loadChatImagePreview(
        animated: true,
        loadThumbnail: () async => data!.buffer.asUint8List(),
        loadOriginal: () async => throw StateError('original is offline'));
    final codec = await ui.instantiateImageCodec(preview);
    expect(codec.frameCount, 1);
    codec.dispose();
  });
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
  test(
      'GIF without thumbnail becomes static while legacy static keeps original',
      () async {
    final original = Uint8List.fromList([1, 2, 3]);
    expect(
        (await loadChatImagePreview(
                animated: true,
                loadThumbnail: () async => throw StateError('static thumbnail'),
                loadOriginal: () async => mediaTestGif()))
            .take(8),
        [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(
        await loadChatImagePreview(
            animated: false,
            loadThumbnail: () async => null,
            loadOriginal: () async => original),
        same(original));
  });
}
