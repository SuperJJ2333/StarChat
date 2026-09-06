import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/ui/chat/chat_search_page.dart';

ChatSearchMessage msg(int n, {ChatSearchMediaCategory? category}) => ChatSearchMessage(
  eventId: 'e$n', senderId: '@a:x', senderDisplayName: 'A',
  timestamp: DateTime(2026, 9, 6), timelineOrder: n,
  visibleText: 'hello $n', mediaCategory: category, hasMedia: category != null,
);

void main() {
  test('ordinary uncancelled debounce must return the actual result', () async {
    final c = ChatSearchQueryController(
      debounce: const Duration(milliseconds: 1),
      search: (f, {cursor, limit = 50}) async => [msg(1)],
    )..setKeyword('hello');
    final page = await c.scheduleDebounced();
    expect(page.stale, isFalse);
    expect(page.items, hasLength(1));
  });

  test('superseded debounce must not leave an extra query timer alive', () async {
    var calls = 0;
    final c = ChatSearchQueryController(
      debounce: const Duration(milliseconds: 5),
      search: (f, {cursor, limit = 50}) async { calls++; return []; },
    )..setKeyword('hello');
    c.scheduleDebounced();
    c.scheduleDebounced();
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(calls, 1);
  });

  testWidgets('scrolling the real search page loads results after the first 50', (tester) async {
    var calls = 0;
    await tester.pumpWidget(CupertinoApp(home: ChatSearchPage(
      isGroup: true, memberEntries: const [], onJumpToMessage: (_) {},
      search: (f, {cursor, limit = 50}) async {
        calls++;
        return cursor == null ? [for (var i = 0; i < 50; i++) msg(i)] : [msg(50)];
      },
    )));
    await tester.enterText(find.byKey(const Key('chat-search-input')), 'hello');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const Key('chat-search-results')), const Offset(0, -10000));
    await tester.pumpAndSettle();
    expect(calls, greaterThan(1));
  });

  testWidgets('selecting an available calendar day actually requests a message jump', (tester) async {
    final jumps = <String>[];
    await tester.pumpWidget(CupertinoApp(home: ChatSearchPage(
      isGroup: true, memberEntries: const [], onJumpToMessage: jumps.add,
      datesWithMessages: {DateTime(2026, 9, 6)},
      earliestMonth: DateTime(2026, 9), latestMonth: DateTime(2026, 9),
      search: (f, {cursor, limit = 50}) async => [msg(1)],
    )));
    await tester.tap(find.byKey(const Key('chat-search-filter-date')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('calendar-day-6')));
    await tester.pumpAndSettle();
    expect(jumps, isNotEmpty);
  });

  testWidgets('media filter renders media grid rather than ordinary message rows', (tester) async {
    await tester.pumpWidget(CupertinoApp(home: ChatSearchPage(
      isGroup: true, memberEntries: const [], onJumpToMessage: (_) {},
      search: (f, {cursor, limit = 50}) async => [msg(1, category: ChatSearchMediaCategory.imageVideo)],
    )));
    await tester.tap(find.byKey(const Key('chat-search-filter-media')));
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);
  });
}
