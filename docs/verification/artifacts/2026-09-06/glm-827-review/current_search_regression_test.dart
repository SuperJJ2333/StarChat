import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/ui/chat/chat_search_page.dart';

ChatSearchMessage msg(int i, {ChatSearchMediaCategory? category}) => ChatSearchMessage(
  eventId: 'e$i', senderId: '@a:x', senderDisplayName: 'A', timestamp: DateTime(2026,9,6),
  timelineOrder: i, visibleText: 'hello $i', mediaCategory: category, hasMedia: category != null,
);
void main() {
  testWidgets('second page remains rendered after build', (tester) async {
    var calls = 0;
    await tester.pumpWidget(CupertinoApp(home: ChatSearchPage(
      isGroup: true, memberEntries: const [], onJumpToMessage: (_) {},
      search: (f, {cursor, limit = 50}) async {
        calls++;
        if (cursor == null) return [for (var i=0;i<50;i++) msg(i)];
        return cursor.order == 49 ? [msg(50)] : [];
      },
    )));
    await tester.enterText(find.byKey(const Key('chat-search-input')), 'hello');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pump();
    final list = tester.widget<ListView>(find.byKey(const Key('chat-search-results')));
    list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(calls, greaterThan(1), reason: 'prove pagination actually executed');
    final rebuilt = tester.widget<ListView>(find.byKey(const Key('chat-search-results')));
    expect((rebuilt.childrenDelegate as SliverChildBuilderDelegate).childCount, 52,
      reason: '51 results plus footer must survive rebuilding');
  });

  testWidgets('image category uses media layout on actual search route', (tester) async {
    await tester.pumpWidget(CupertinoApp(home: ChatSearchPage(
      isGroup: true, memberEntries: const [], onJumpToMessage: (_) {},
      search: (f, {cursor, limit=50}) async => [msg(1, category: ChatSearchMediaCategory.imageVideo)],
    )));
    await tester.tap(find.byKey(const Key('chat-search-filter-media')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(GridView), findsOneWidget);
  });

  test('immediate search settles superseded scheduled future', () async {
    final c = ChatSearchQueryController(
      debounce: const Duration(milliseconds: 20),
      search: (f, {cursor, limit=50}) async => [msg(1)],
    )..setKeyword('hello');
    var settled = false;
    c.scheduleDebounced().then((_) { settled = true; });
    await c.executeNow();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(settled, isTrue, reason: 'Enter/search-button must not leave cancelled future pending');
  });
}
