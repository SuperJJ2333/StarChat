import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_call_bubble.dart';
import 'package:liuhetong_mobile/ui/foundation/changliao_icons.dart';

/// BUG-14：通话摘要气泡必须能一眼区分语音/视频，且点击可直接再次拨打。
void main() {
  Future<void> pumpBubble(
    WidgetTester tester, {
    required bool video,
    required bool connected,
    VoidCallback? onRedial,
  }) async {
    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: Center(
          child: WeChatCallBubble(
            video: video,
            connected: connected,
            duration: const Duration(minutes: 1, seconds: 23),
            onRedial: onRedial,
          ),
        ),
      ),
    ));
  }

  testWidgets('视频通话气泡显示视频图标与「视频通话」文案', (tester) async {
    await pumpBubble(tester, video: true, connected: true);

    expect(find.byIcon(ChangliaoIcons.videoCallFilled), findsOneWidget);
    expect(find.byIcon(ChangliaoIcons.voiceCallFilled), findsNothing);
    expect(find.textContaining('视频通话时长'), findsOneWidget);
  });

  testWidgets('语音通话气泡显示话筒图标与「语音通话」文案', (tester) async {
    await pumpBubble(tester, video: false, connected: true);

    expect(find.byIcon(ChangliaoIcons.voiceCallFilled), findsOneWidget);
    expect(find.byIcon(ChangliaoIcons.videoCallFilled), findsNothing);
    expect(find.textContaining('语音通话时长'), findsOneWidget);
  });

  testWidgets('点击气泡直接再次拨打同一类型', (tester) async {
    var redials = 0;
    await pumpBubble(tester, video: true, connected: false, onRedial: () {
      redials++;
    });

    expect(find.textContaining('视频通话'), findsOneWidget,
        reason: '未接通也应能看出是视频通话（已取消）');
    await tester.tap(find.byKey(const Key('call-summary-redial')));
    expect(redials, 1, reason: '点击通话气泡应直接再次拨打');
  });

  testWidgets('未提供重拨回调时点击不抛错（如群聊无固定对端）', (tester) async {
    await pumpBubble(tester, video: false, connected: true);

    await tester.tap(find.byKey(const Key('call-summary-redial')));
    tester.binding.delayed(const Duration(milliseconds: 10));
  });
}
