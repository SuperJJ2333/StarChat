import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_message_bubble.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';

Widget _wrap(Widget child) => CupertinoApp(home: CupertinoPageScaffold(child: child));

void main() {
  testWidgets('incoming bubble shows the sender name above the bubble edge',
      (tester) async {
    await tester.pumpWidget(_wrap(const WeChatMessageBubble(
      direction: MessageDirection.incoming,
      senderName: '项目小艾',
      avatar: SizedBox(),
      content: Text('你好'),
    )));

    final name = find.byKey(const Key('message-sender-name'));
    expect(name, findsOneWidget);
    final text = tester.widget<Text>(find.descendant(
      of: name,
      matching: find.text('项目小艾'),
    ));
    expect(text.style!.fontSize, 12);
    expect(text.style!.color, WeChatColors.messageSenderName);

    // Aligned with the bubble edge: avatar (40) + gutter (8).
    final nameLeft = tester.getTopLeft(find.text('项目小艾')).dx;
    final avatarLeft = tester
        .getTopLeft(find.byKey(const Key('message-avatar-slot')))
        .dx;
    expect(nameLeft, avatarLeft + 48);
  });

  testWidgets('outgoing bubble never shows a sender name', (tester) async {
    await tester.pumpWidget(_wrap(const WeChatMessageBubble(
      direction: MessageDirection.outgoing,
      senderName: '我自己',
      avatar: SizedBox(),
      content: Text('你好'),
    )));

    expect(find.byKey(const Key('message-sender-name')), findsNothing);
  });

  testWidgets('incoming bubble without a sender name renders none',
      (tester) async {
    await tester.pumpWidget(_wrap(const WeChatMessageBubble(
      direction: MessageDirection.incoming,
      avatar: SizedBox(),
      content: Text('你好'),
    )));

    expect(find.byKey(const Key('message-sender-name')), findsNothing);
  });
}
