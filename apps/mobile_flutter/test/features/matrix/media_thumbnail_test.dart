import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_thumbnail.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('chatThumbnailTargetSize caps longest edge at 800 (3:2 photo)', () {
    final (width, height) = chatThumbnailTargetSize(2400, 1600);
    expect(width, 800);
    expect(height, 533);
    expect(width / height, closeTo(1.5, 0.01));
  });

  test('chatThumbnailTargetSize handles portrait orientation', () {
    final (width, height) = chatThumbnailTargetSize(1500, 3000);
    expect(width, 400);
    expect(height, 800);
  });

  test('chatThumbnailTargetSize never upscales small images', () {
    final (width, height) = chatThumbnailTargetSize(320, 200);
    expect((width, height), (320, 200));
  });

  test('chatThumbnailTargetSize clamps degenerate dimensions to 1px', () {
    expect(chatThumbnailTargetSize(0, 0), (1, 1));
    expect(chatThumbnailTargetSize(1600, 1), (800, 1));
  });

  test('chatThumbnailTargetSize honours custom max edge', () {
    final (width, height) = chatThumbnailTargetSize(2400, 1600, maxEdge: 480);
    expect(width, 480);
    expect(height, 320);
  });

  test('decodeImageDimensions returns real pixel size', () async {
    final source = await _buildPng(640, 480);
    final dims = await decodeImageDimensions(source);
    expect(dims, isNotNull);
    expect(dims!.$1, 640);
    expect(dims.$2, 480);
  });

  test('garbage input yields null instead of throwing', () async {
    expect(
      await buildChatImageThumbnail(Uint8List.fromList([1, 2, 3])),
      isNull,
    );
    expect(await decodeImageDimensions(Uint8List.fromList([9, 9, 9])), isNull);
  });
}

/// 生成指定尺寸的纯色 PNG（dart:ui 合成器可用，无需平台通道）。
Future<Uint8List> _buildPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}
