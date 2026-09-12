import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/app_connection_status.dart';
import 'package:liuhetong_mobile/ui/chat/encrypted_media_view.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_video_message.dart';

Uint8List _onePixelPng() => Uint8List.fromList(const [
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
      0x0A,
      0x49,
      0x44,
      0x41,
      0x54,
      0x78,
      0x9C,
      0x63,
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

void main() {
  final hub = AppConnectionStatusHub.shared;

  setUp(() {
    final owner = Object();
    hub.bind(
        owner, ValueNotifier(AppConnectionStatus.offline), (value) => value);
    addTearDown(() => hub.unbind(owner));
  });

  testWidgets('chat image viewer keeps a valid cached source while offline',
      (tester) async {
    final bytes = _onePixelPng();
    await tester
        .pumpWidget(CupertinoApp(home: ImageViewerPage(previewBytes: bytes)));
    await tester.pump();
    await tester.pump();
    expect(find.text('网络不可用，联网后自动重试'), findsOneWidget);
    expect(find.byType(ImageViewerPage), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image).first);
    expect(image.image, isA<ResizeImage>());
  });

  testWidgets('raw chat video viewer exposes offline status', (tester) async {
    await tester.pumpWidget(CupertinoApp(
        home: VideoViewerPage(
            loadFile: () =>
                Future<File>.error(const SocketException('offline')))));
    await tester.pump();
    await tester.pump();
    expect(find.text('网络不可用，联网后自动重试'), findsOneWidget);
    expect(find.byType(VideoViewerPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
