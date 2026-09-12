import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/notification/conversation_notification_mode_tile.dart';

void main() {
  testWidgets(
      'notification choices start collapsed and collapse after selection',
      (tester) async {
    ConversationNotificationMode? selected;
    await tester.pumpWidget(CupertinoApp(
        home: CupertinoPageScaffold(
            child: ConversationNotificationSection(
                muted: false,
                attention: false,
                onChanged: (value) => selected = value))));
    expect(find.text('静音'), findsNothing);
    await tester.tap(find.text('消息通知'));
    await tester.pumpAndSettle();
    expect(find.text('特别关注'), findsOneWidget);
    await tester.tap(find.text('静音'));
    await tester.pumpAndSettle();
    expect(selected, ConversationNotificationMode.muted);
    // 新行为：切到静音保持展开（展示嵌套子选项），切走才收起。
    expect(find.text('特别关注'), findsOneWidget);
    await tester.tap(find.text('特别关注'));
    await tester.pumpAndSettle();
    expect(selected, ConversationNotificationMode.attention);
    expect(find.text('静音'), findsNothing);
  });
}
