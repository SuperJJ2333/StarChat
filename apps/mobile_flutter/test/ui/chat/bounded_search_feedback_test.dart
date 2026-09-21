import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/ui/chat/chat_search_page.dart';

void main() {
  testWidgets('empty partial scan offers continuation, never final no matches',
      (tester) async {
    var batches = 0;
    await tester.pumpWidget(CupertinoApp(
        home: ChatSearchPage(
      isGroup: false,
      memberEntries: const [],
      onJumpToMessage: (_) {},
      search: (f, {cursor, limit = 50}) async => [],
      searchBatch: (f, {cursor, limit = 50}) async {
        batches++;
        return ChatSearchSlice(
            items: const [],
            nextCursor: batches == 1
                ? const ChatSearchCursor(order: 1, eventId: 'scan')
                : null);
      },
    )));
    await tester.enterText(find.byKey(const Key('chat-search-input')), 'rare');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('未找到符合条件的聊天记录'), findsNothing);
    expect(find.byKey(const Key('chat-search-continue')), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat-search-continue')));
    await tester.pumpAndSettle();
    expect(batches, 2);
    expect(find.text('未找到符合条件的聊天记录'), findsOneWidget);
  });

  testWidgets('opening calendar cancels pending keyword debounce',
      (tester) async {
    var searches = 0;
    var invalidations = 0;
    await tester.pumpWidget(CupertinoApp(
        home: ChatSearchPage(
      isGroup: false,
      memberEntries: const [],
      onJumpToMessage: (_) {},
      onSearchInvalidated: () => invalidations++,
      search: (f, {cursor, limit = 50}) async {
        searches++;
        return [];
      },
    )));
    await tester.enterText(find.byKey(const Key('chat-search-input')), 'rare');
    final before = invalidations;
    await tester.tap(find.byKey(const Key('chat-search-filter-date')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(searches, 0);
    expect(invalidations, greaterThan(before));
    await tester.pumpWidget(const SizedBox());
  });
}
