import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/contain_image_bubble.dart';

/// 规格 #10 UI 接线：任意比例图片气泡组件。
void main() {
  // 1x1 透明 PNG。
  final png = Uint8List.fromList(const [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1F,
    0x15,
    0xC4,
    0x89,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x44,
    0x41,
    0x54,
    0x78,
    0x9C,
    0x62,
    0x00,
    0x01,
    0x00,
    0x00,
    0x05,
    0x00,
    0x01,
    0x0D,
    0x0A,
    0x2D,
    0xB4,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82,
  ]);

  test('unsafe received GIF never reaches an image decoder', () {
    final huge = Uint8List.fromList(
        [71, 73, 70, 56, 57, 97, 255, 255, 255, 255, 0, 0, 0, 59]);
    final provider = boundedChatImageProvider(huge) as ResizeImage;
    final bytes = (provider.imageProvider as MemoryImage).bytes;
    expect(identical(bytes, huge), isFalse);
    expect(bytes.take(4), [137, 80, 78, 71]);
  });

  testWidgets('加载完成后渲染图片（contain 适配）', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: Center(
        child: ContainImageBubble(
          load: () async => png,
          initialBytes: png,
          availableWidth: 400,
          availableHeight: 800,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsWidgets, reason: '图片渲染');
    final image = tester.widget<Image>(find.byType(Image).first);
    expect(image.image, isA<ResizeImage>());
    final resize = image.image as ResizeImage;
    expect(resize.width, 720);
    expect(resize.height, 720);
    expect(resize.policy, ResizeImagePolicy.fit);
  });

  testWidgets('加载失败显示重试入口', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: Center(
        child: ContainImageBubble(
          load: () async => throw StateError('decrypt failed'),
          availableWidth: 400,
          availableHeight: 800,
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('图片加载失败，点击重试'), findsOneWidget);
  });

  testWidgets('网格单元完整适配不裁切（contain）', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: Center(
        child:
            ContainGridCell(bytes: Uint8List.fromList(const []), cellSize: 120),
      ),
    ));
    expect(find.byType(Image), findsOneWidget);
  });
}
