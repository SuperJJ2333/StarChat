import 'package:flutter/cupertino.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_video_message.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_message_bubble.dart';

void main() {
  testWidgets('视频文件加载无响应时提供超时重试', (tester) async {
    await tester.pumpWidget(CupertinoApp(
        home: VideoViewerPage(loadFile: () => Completer<File>().future)));
    expect(find.text('正在加载视频…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(find.byKey(const Key('video-viewer-retry')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('未知视频时长不伪装成零秒，卡片点击可以打开播放器', (tester) async {
    var opened = 0;
    await tester.pumpWidget(CupertinoApp(
        home: Center(
            child: WeChatMessageBubble(
                direction: MessageDirection.outgoing,
                decorateContent: false,
                content: VideoMessageCard(
                    duration: null, onOpen: () => opened++)))));
    await tester.tap(find.byIcon(CupertinoIcons.play_arrow_solid));
    expect(opened, 1);
    expect(find.text('0:00'), findsNothing);
    expect(find.text('--:--'), findsOneWidget);
  });
}
