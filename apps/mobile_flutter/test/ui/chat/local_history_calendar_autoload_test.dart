import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_media_shared_logic.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/ui/chat/chat_search_page.dart';

void main() {
  testWidgets(
      'unconfirmed dates cannot be clicked while month metadata is loading',
      (tester) async {
    var calls = 0;
    final pending = Completer<RoomHistoryMonthDays>();
    await tester.pumpWidget(CupertinoApp(
        home: CalendarPickerPage(
            latest: const CalendarMonth(2026, 9),
            loadMonth: (_) => pending.future,
            onDateLookup: (_) async {
              calls++;
              return CalendarDateLookupResult.incomplete;
            })));
    await tester.pump();
    await tester.tap(find.byKey(const Key('calendar-day-5')));
    await tester.pump();
    expect(calls, 0);
    pending.complete(RoomHistoryMonthDays(
        month: const CalendarMonth(2026, 9),
        coverageComplete: true,
        dayStates: {
          for (var d = 1; d <= 30; d++) d: RoomHistoryDayState.knownEmpty
        }));
    await tester.pumpAndSettle();
  });
  testWidgets(
      'short screen and empty continuation automatically advance with no load button',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(CupertinoApp(
        home: ChatSearchPage(
            isGroup: false,
            memberEntries: const [],
            onJumpToMessage: (_) {},
            search: (_, {cursor, limit = 50}) async => [],
            searchBatch: (_, {cursor, limit = 50}) async {
              calls++;
              return ChatSearchSlice(
                  items: const [],
                  nextCursor: calls == 1
                      ? const ChatSearchCursor(order: 1, eventId: 'scan')
                      : null);
            })));
    await tester.enterText(
        find.byKey(const Key('chat-search-input')), 'needle');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byKey(const Key('chat-search-continue')), findsNothing);
    expect(find.byKey(const Key('chat-search-load-more')), findsNothing);
  });
  testWidgets(
      'an unchanged continuation stops automatic paging and remains retryable',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(CupertinoApp(
        home: ChatSearchPage(
            isGroup: false,
            memberEntries: const [],
            onJumpToMessage: (_) {},
            search: (_, {cursor, limit = 50}) async => [],
            searchBatch: (_, {cursor, limit = 50}) async {
              calls++;
              return const ChatSearchSlice(
                  items: [],
                  nextCursor: ChatSearchCursor(order: 1, eventId: 'stuck'));
            })));
    await tester.enterText(
        find.byKey(const Key('chat-search-input')), 'needle');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byKey(const Key('chat-search-page-retry')), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 2, reason: 'No-progress cursor must not create a busy loop');
    await tester.tap(find.byKey(const Key('chat-search-page-retry')));
    await tester.pumpAndSettle();
    expect(calls, 3);
    expect(tester.takeException(), isNull);
  });
}
