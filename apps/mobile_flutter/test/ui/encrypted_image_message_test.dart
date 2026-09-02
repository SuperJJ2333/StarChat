import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/encrypted_media_view.dart';

Uint8List _pngBytes() => Uint8List.fromList(const [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, //
      0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01,
      0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F,
      0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
      0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00,
      0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
      0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ]);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester
      .pumpWidget(CupertinoApp(home: CupertinoPageScaffold(child: child)));
  await tester.pump();
}

void main() {
  testWidgets('cached bytes render synchronously at the fixed thumbnail size',
      (tester) async {
    var loads = 0;
    await _pump(
      tester,
      EncryptedImageMessage(
        initialBytes: _pngBytes(),
        load: () async {
          loads++;
          return _pngBytes();
        },
      ),
    );

    expect(loads, 0, reason: '缓存命中不应触发任何加载');
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, BoxFit.cover);
    final box = tester.widget<SizedBox>(
      find.ancestor(of: find.byType(Image), matching: find.byType(SizedBox)),
    );
    expect(box.width, EncryptedImageMessage.thumbnailWidth);
    expect(box.height, EncryptedImageMessage.thumbnailHeight);
  });

  testWidgets('placeholder shares the loaded thumbnail size to avoid jumps',
      (tester) async {
    await _pump(
      tester,
      EncryptedImageMessage(
        load: () async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return _pngBytes();
        },
      ),
    );

    final placeholder = tester.widget<SizedBox>(
      find.ancestor(
        of: find.byType(CupertinoActivityIndicator),
        matching: find.byType(SizedBox),
      ),
    );
    expect(placeholder.width, EncryptedImageMessage.thumbnailWidth);
    expect(placeholder.height, EncryptedImageMessage.thumbnailHeight);

    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    final loadedBox = tester.getSize(find.byType(Image));
    expect(loadedBox.width, EncryptedImageMessage.thumbnailWidth);
    expect(loadedBox.height, EncryptedImageMessage.thumbnailHeight);
  });

  testWidgets('load failures offer a retry that reloads once', (tester) async {
    var attempts = 0;
    await _pump(
      tester,
      EncryptedImageMessage(load: () async {
        attempts++;
        if (attempts == 1) throw StateError('decrypt failed');
        return _pngBytes();
      }),
    );
    await tester.pumpAndSettle();

    expect(find.text('图片加载失败，点击重试'), findsOneWidget);
    await tester.tap(find.text('图片加载失败，点击重试'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.byType(Image), findsOneWidget);
  });
}
