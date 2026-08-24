import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_nudge_notice.dart';

void main() {
  testWidgets('nudge notice centers text without a message bubble',
      (tester) async {
    await tester.pumpWidget(const CupertinoApp(
      home: WeChatNudgeNotice(text: '小明拍了拍我'),
    ));
    expect(find.byKey(const Key('nudge-notice')), findsOneWidget);
    expect(find.byKey(const Key('nudge-notice-bubble')), findsNothing);
    expect(
      tester
          .widget<Align>(find.byKey(const Key('nudge-notice-align')))
          .alignment,
      Alignment.center,
    );
  });
}
