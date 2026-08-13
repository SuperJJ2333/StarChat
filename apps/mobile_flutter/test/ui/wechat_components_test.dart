import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_message_bubble.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_unread_badge.dart';
import 'package:liuhetong_mobile/ui/finance/wechat_red_packet_card.dart';

void main() {
  testWidgets('outgoing message uses WeChat green bubble', (tester) async {
    await tester.pumpWidget(const CupertinoApp(home: WeChatMessageBubble(direction: MessageDirection.outgoing, content: Text('你好'))));
    final box = tester.widget<DecoratedBox>(find.byType(DecoratedBox).last);
    expect((box.decoration as BoxDecoration).color, const Color(0xFF95EC69));
  });
  testWidgets('unread badge caps its label at 99+', (tester) async {
    await tester.pumpWidget(const CupertinoApp(home: WeChatUnreadBadge(count: 100)));
    expect(find.text('99+'), findsOneWidget);
  });
  testWidgets('expired red packet displays its authoritative visual state', (tester) async {
    await tester.pumpWidget(const CupertinoApp(home: WeChatRedPacketCard(greeting: '恭喜发财', state: RedPacketVisualState.expired)));
    expect(find.text('已过期'), findsOneWidget);
  });
}
