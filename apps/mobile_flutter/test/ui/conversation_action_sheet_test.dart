import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/conversation_action_sheet.dart';

void main() {
  testWidgets('conversation action sheet exposes all WeChat actions',
      (tester) async {
    ConversationAction? action;
    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: Center(
          child: CupertinoButton(
            onPressed: () => showConversationActionSheet(
              tester.element(find.byType(CupertinoButton)),
              pinned: false,
              manualUnread: false,
              onAction: (value) => action = value,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('标记未读'), findsOneWidget);
    expect(find.text('置顶该聊天'), findsOneWidget);
    expect(find.text('不显示该聊天'), findsOneWidget);
    expect(find.text('删除该聊天'), findsOneWidget);
    await tester.tap(find.text('标记未读'));
    await tester.pumpAndSettle();
    expect(action, ConversationAction.markUnread);
  });

  testWidgets('BUG-15 已标未读的会话显示「取消未读」，选择后回传 clearUnread',
      (tester) async {
    ConversationAction? action;
    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: Center(
          child: CupertinoButton(
            onPressed: () => showConversationActionSheet(
              tester.element(find.byType(CupertinoButton)),
              pinned: false,
              manualUnread: true,
              onAction: (value) => action = value,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('标记未读'), findsNothing,
        reason: '已标未读的会话不得再显示「标记未读」（重复标记无意义）');
    expect(find.text('取消未读'), findsOneWidget);
    await tester.tap(find.text('取消未读'));
    await tester.pumpAndSettle();
    expect(action, ConversationAction.clearUnread);
  });
}
