import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/encrypted_media_view.dart';

/// 1×1 合法 PNG（尺寸解码可得 1×1）。
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
  group('formatMediaSize', () {
    test('uses KB below 1MB and MB above, computed from bytes', () {
      expect(formatMediaSize(512), '1K', reason: '不足 1K 回退 1K');
      expect(formatMediaSize(358 * 1024), '358K');
      expect(formatMediaSize(1024 * 1024 + 400 * 1024), '1.4M');
      expect(formatMediaSize(12 << 20), '12M', reason: '10M 以上取整');
    });
  });

  testWidgets('viewer shows thumbnail placeholder with size-aware actions',
      (tester) async {
    final preview = Uint8List(358 * 1024);
    await tester.pumpWidget(CupertinoApp(
      home: ImageViewerPage(
        previewBytes: preview,
        loadOriginal: () async => pngBytes(),
        forwardTargets: const [
          (roomId: 'room-1', title: '文件传输助手'),
        ],
        forwardTo: (_) async {},
      ),
    ));
    await tester.pump();

    expect(find.text('查看原图 358K'), findsOneWidget,
        reason: '点击前仅占位缩略图，按钮按本次字节动态显示大小');
    expect(find.byKey(const Key('viewer-download')), findsOneWidget);
    expect(find.byKey(const Key('viewer-forward')), findsOneWidget);

    // 下载/转发按钮：深灰 #555555 圆形背景 + 白色图标。
    for (final key in const [
      Key('viewer-download'),
      Key('viewer-forward'),
    ]) {
      final container = tester.widget<Container>(
        find.descendant(
          of: find.byKey(key),
          matching: find.byType(Container),
        ),
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, const Color(0xFF555555), reason: '$key 深灰背景');
      expect(decoration.shape, BoxShape.circle);
      final icon = container.child! as Icon;
      expect(icon.color, CupertinoColors.white, reason: '$key 白色图标');
    }
  });

  testWidgets('view-original loads async and shows actual dimensions',
      (tester) async {
    final preview = Uint8List(358 * 1024);
    var loads = 0;
    await tester.pumpWidget(CupertinoApp(
      home: ImageViewerPage(
        previewBytes: preview,
        loadOriginal: () async {
          loads++;
          return pngBytes();
        },
      ),
    ));
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('viewer-view-original')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(loads, 1, reason: '点击后才异步加载原图');
    expect(find.text('已展示原图 1×1'), findsOneWidget,
        reason: '加载完成后展示原图实际像素尺寸');
    expect(find.text('查看原图 358K'), findsNothing);
  });

  testWidgets('forward picks a target session and invokes the flow',
      (tester) async {
    final forwarded = <String>[];
    await tester.pumpWidget(CupertinoApp(
      home: ImageViewerPage(
        previewBytes: pngBytes(),
        forwardTargets: const [
          (roomId: 'room-1', title: '文件传输助手'),
          (roomId: 'room-2', title: '测试群'),
        ],
        forwardTo: (roomId) async => forwarded.add(roomId),
      ),
    ));
    await tester.pump();

    await tester.tap(find.byKey(const Key('viewer-forward')));
    await tester.pumpAndSettle();
    expect(find.text('转发到'), findsOneWidget, reason: '调起会话选择转发流程');

    await tester.tap(find.text('文件传输助手'));
    await tester.pumpAndSettle();
    expect(forwarded, ['room-1']);
    expect(find.text('已转发到「文件传输助手」'), findsOneWidget);
  });

  testWidgets('image message tap opens the full viewer', (tester) async {
    final forwarded = <String>[];
    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: EncryptedImageMessage(
          initialBytes: pngBytes(),
          load: () async => pngBytes(),
          forwardTargets: const [
            (roomId: 'room-1', title: '文件传输助手'),
          ],
          forwardTo: (roomId) async => forwarded.add(roomId),
        ),
      ),
    ));
    await tester.pump();

    await tester.tap(find.byType(EncryptedImageMessage));
    await tester.pumpAndSettle();

    expect(find.byType(ImageViewerPage), findsOneWidget);
    expect(find.byKey(const Key('viewer-download')), findsOneWidget,
        reason: '收发任意图片消息都提供下载');
    expect(find.byKey(const Key('viewer-forward')), findsOneWidget,
        reason: '收发任意图片消息都提供转发');
  });

  testWidgets('viewer without original loader hides view-original and forward',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: ImageViewerPage(previewBytes: pngBytes()),
    ));
    await tester.pump();

    expect(find.byKey(const Key('viewer-view-original')), findsNothing);
    expect(find.byKey(const Key('viewer-forward')), findsNothing);
    expect(find.byKey(const Key('viewer-download')), findsOneWidget);
  });
}
