import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/message_action.dart';
import 'package:liuhetong_mobile/ui/chat/message_bubble_menu.dart';

void main() {
  testWidgets('voice route action uses the compact existing message menu',
      (tester) async {
    MessageAction? selected;
    await tester.pumpWidget(CupertinoApp(
        home: CupertinoPageScaffold(
            child: MessageBubbleMenu(actions: const {
      MessageAction.voiceEarpiece,
      MessageAction.reply
    }, onSelected: (action) => selected = action))));
    expect(find.text('听筒播放'), findsOneWidget);
    expect(find.text('扬声器播放'), findsNothing);
    await tester.tap(find.text('听筒播放'));
    expect(selected, MessageAction.voiceEarpiece);
  });
  testWidgets('copy is presented FIRST in the bubble menu', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: Align(
          alignment: Alignment.topCenter,
          child: MessageBubbleMenu(
            actions: const {
              MessageAction.forward,
              MessageAction.copy,
              MessageAction.deleteLocal,
              MessageAction.recall,
            },
            onSelected: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump();

    final copyFinder = find.byKey(const Key('message-action-copy'));
    final forwardFinder = find.byKey(const Key('message-action-forward'));
    expect(copyFinder, findsOneWidget);
    expect(forwardFinder, findsOneWidget);
    expect(
      tester.getTopLeft(copyFinder).dx,
      lessThan(tester.getTopLeft(forwardFinder).dx),
      reason: '复制必须排在菜单第一位',
    );
  });

  testWidgets('tapping a menu item emits the action', (tester) async {
    MessageAction? selected;
    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: Align(
          alignment: Alignment.topCenter,
          child: MessageBubbleMenu(
            actions: const {MessageAction.copy, MessageAction.forward},
            onSelected: (action) => selected = action,
          ),
        ),
      ),
    ));
    await tester.pump();

    await tester.tap(find.byKey(const Key('message-action-copy')));
    await tester.pump();
    expect(selected, MessageAction.copy);
  });
}
