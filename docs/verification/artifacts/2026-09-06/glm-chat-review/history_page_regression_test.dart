import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_info_page.dart';

void main() {
  final entries = [
    GroupChatHistoryEntry(sender: 'HelloName', senderId: '@a:x',
      eventId: 'a', text: 'unrelated body', timestamp: DateTime(2026, 9, 6)),
  ];

  testWidgets('actual history page initially shows no message rows', (tester) async {
    await tester.pumpWidget(CupertinoApp(home: GroupChatHistorySearchPage(entries: entries)));
    await tester.pumpAndSettle();
    expect(find.text('unrelated body'), findsNothing);
    expect(find.text('请选择筛选条件或输入关键字'), findsOneWidget);
  });

  testWidgets('actual keyword search must not match sender name alone', (tester) async {
    await tester.pumpWidget(CupertinoApp(home: GroupChatHistorySearchPage(entries: entries)));
    await tester.enterText(find.byType(CupertinoSearchTextField), 'hello');
    await tester.pumpAndSettle();
    expect(find.text('unrelated body'), findsNothing);
  });

  testWidgets('actual date selector must use calendar instead of wheel', (tester) async {
    await tester.pumpWidget(CupertinoApp(home: GroupChatHistorySearchPage(entries: entries)));
    await tester.tap(find.byKey(const Key('history-category-date')));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoDatePicker), findsNothing);
  });
}
