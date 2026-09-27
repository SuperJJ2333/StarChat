import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/app_connection_status.dart';
import 'package:liuhetong_mobile/ui/chat/encrypted_media_view.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_video_message.dart';
import 'package:liuhetong_mobile/ui/components/network_status_capsule.dart';

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

  testWidgets('raw chat video keeps offline loading and retry inline',
      (tester) async {
    final pending = [Completer<File>(), Completer<File>()];
    var loads = 0;
    await tester.pumpWidget(CupertinoApp(
        home: VideoViewerPage(loadFile: () => pending[loads++].future)));
    await tester.pump();
    expect(find.byType(VideoViewerPage), findsOneWidget);
    expect(find.byType(WeChatNetworkStatusCapsule), findsNothing);
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    expect(find.text('正在加载视频…'), findsOneWidget);

    pending.first.completeError(const SocketException('offline'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(WeChatNetworkStatusCapsule), findsNothing);
    expect(find.text('视频加载失败，请检查网络后重试'), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(find.byKey(const Key('video-viewer-retry')), findsOneWidget);

    await tester.tap(find.byKey(const Key('video-viewer-retry')));
    await tester.pump();
    expect(loads, 2);
    expect(find.byType(WeChatNetworkStatusCapsule), findsNothing);
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    expect(find.text('正在加载视频…'), findsOneWidget);

    pending.last.completeError(const SocketException('still offline'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(WeChatNetworkStatusCapsule), findsNothing);
    expect(find.text('视频加载失败，请检查网络后重试'), findsOneWidget);
    expect(find.byKey(const Key('video-viewer-retry')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
