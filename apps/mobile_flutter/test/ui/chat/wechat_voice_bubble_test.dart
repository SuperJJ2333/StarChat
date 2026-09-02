import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_voice_bubble.dart';

/// 语音气泡播放动画（QQ 式）：高亮进度随播放从左到右扫过音纹。
void main() {
  testWidgets('idle bubble keeps the sweep at zero', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: WeChatVoiceBubble(
          duration: const Duration(seconds: 6),
          state: VoicePlaybackState.idle,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(_progress(tester), 0);
  });

  testWidgets('playing state sweeps the highlight left to right',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: WeChatVoiceBubble(
          key: const Key('voice-bubble'),
          duration: const Duration(seconds: 6),
          state: VoicePlaybackState.idle,
        ),
      ),
    ));
    await tester.pump();

    // 切换为播放中：进度按语音时长从 0 开始推进。
    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: WeChatVoiceBubble(
          key: const Key('voice-bubble'),
          duration: const Duration(seconds: 6),
          state: VoicePlaybackState.playing,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    final midProgress = _progress(tester);
    expect(midProgress, greaterThan(0.3), reason: '播放到一半应扫过约一半音纹');
    expect(midProgress, lessThan(0.95));

    await tester.pump(const Duration(seconds: 4));
    expect(_progress(tester), 1, reason: '扫过时长与语音时长一致，播完即全亮');
  });

  testWidgets('stopping playback resets the sweep', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: WeChatVoiceBubble(
          duration: const Duration(seconds: 6),
          state: VoicePlaybackState.playing,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(_progress(tester), greaterThan(0));

    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: WeChatVoiceBubble(
          duration: const Duration(seconds: 6),
          state: VoicePlaybackState.idle,
        ),
      ),
    ));
    await tester.pump();
    expect(_progress(tester), 0, reason: '停止播放后音纹复位');
  });
}

double _progress(WidgetTester tester) {
  final painter = tester.widget<CustomPaint>(
    find.descendant(
      of: find.byType(WeChatVoiceBubble),
      matching: find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter != null,
      ),
    ),
  );
  return (painter.painter! as dynamic).progress as double;
}
