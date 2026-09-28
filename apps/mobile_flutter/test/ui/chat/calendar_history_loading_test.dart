import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_media_shared_logic.dart';
import 'package:liuhetong_mobile/ui/chat/chat_search_page.dart';

/// Local date changes reload confirmed month states; stale lookup results never
/// overwrite another month or a closed calendar.
void main() {
  /// A fully scanned local month with two displayable days.
  RoomHistoryMonthDays unresolvedMonth(CalendarMonth month) =>
      RoomHistoryMonthDays(month: month, coverageComplete: true, dayStates: {
        for (var d = 1; d <= month.daysInMonth; d++)
          d: {5, 15}.contains(d)
              ? RoomHistoryDayState.knownPresent
              : RoomHistoryDayState.knownEmpty
      });

  testWidgets(
      'date lookup stays on the calendar, can cancel a stale result, and retries failures',
      (tester) async {
    final first = Completer<CalendarDateLookupResult>();
    var calls = 0;
    var cancelled = 0;
    await tester.pumpWidget(CupertinoApp(
        home: CalendarPickerPage(
      earliest: const CalendarMonth(2026, 9),
      latest: const CalendarMonth(2026, 9),
      loadMonth: (month) async => unresolvedMonth(month),
      onDateLookup: (_) {
        calls++;
        if (calls == 1) return first.future;
        if (calls == 2) throw StateError('offline');
        return Future.value(CalendarDateLookupResult.located);
      },
      onCancelDateLookup: () => cancelled++,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('calendar-day-5')));
    await tester.pump();
    expect(
        find.byKey(const Key('calendar-date-lookup-loading')), findsOneWidget);
    expect(
        find.byKey(const Key('calendar-date-lookup-cancel')), findsOneWidget);

    await tester.tap(find.byKey(const Key('calendar-date-lookup-cancel')));
    await tester.pump();
    expect(cancelled, 1);
    first.complete(CalendarDateLookupResult.located);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendar-picker-page')), findsOneWidget);

    await tester.tap(find.byKey(const Key('calendar-day-5')));
    await tester.pumpAndSettle();
    expect(find.text('日期定位失败，点击重试'), findsOneWidget);
    await tester.tap(find.text('日期定位失败，点击重试'));
    await tester.pumpAndSettle();
    expect(calls, 3);
    expect(find.byKey(const Key('calendar-picker-page')), findsNothing);
  });

  testWidgets(
      'changed local date snapshot reloads confirmed empty days without a retry toast',
      (tester) async {
    var changed = false;
    var loads = 0;
    await tester.pumpWidget(CupertinoApp(
        home: CalendarPickerPage(
            earliest: const CalendarMonth(2026, 9),
            latest: const CalendarMonth(2026, 9),
            loadMonth: (month) async {
              loads++;
              return changed
                  ? RoomHistoryMonthDays(
                      month: month,
                      coverageComplete: true,
                      dayStates: {
                          for (var d = 1; d <= month.daysInMonth; d++)
                            d: RoomHistoryDayState.knownEmpty
                        })
                  : unresolvedMonth(month);
            },
            onDateLookup: (_) async {
              changed = true;
              return CalendarDateLookupResult.incomplete;
            })));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('calendar-day-5')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(loads, 2);
    expect(
        tester
            .widget<GestureDetector>(find.byKey(const Key('calendar-day-5')))
            .onTap,
        isNull);
    expect(find.byKey(const Key('calendar-month-error')), findsNothing);
    expect(find.textContaining('该日期暂时无法确认'), findsNothing);
    expect(find.text('本日暂无聊天记录'), findsNothing);
  });

  testWidgets('changing month cancels a pending date lookup', (tester) async {
    final pending = Completer<CalendarDateLookupResult>();
    var cancelled = 0;
    await tester.pumpWidget(CupertinoApp(
        home: CalendarPickerPage(
      earliest: const CalendarMonth(2026, 8),
      latest: const CalendarMonth(2026, 9),
      loadMonth: (month) async => unresolvedMonth(month),
      onDateLookup: (_) => pending.future,
      onCancelDateLookup: () => cancelled++,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('calendar-day-5')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('calendar-prev-month')));
    await tester.pump();
    expect(cancelled, 1);
    pending.complete(CalendarDateLookupResult.located);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendar-picker-page')), findsOneWidget);
  });

  testWidgets('changing month clears the prior date lookup outcome',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
        home: CalendarPickerPage(
      earliest: const CalendarMonth(2026, 8),
      latest: const CalendarMonth(2026, 9),
      loadMonth: (month) async => unresolvedMonth(month),
      onDateLookup: (_) async => CalendarDateLookupResult.confirmedEmpty,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('calendar-day-5')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendar-month-error')), findsNothing);
    await tester.tap(find.byKey(const Key('calendar-prev-month')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendar-month-error')), findsNothing);
  });

  testWidgets('一个月只查询一次 metadata，重复返回同一月份复用结果', (tester) async {
    final loads = <CalendarMonth>[];
    await tester.pumpWidget(CupertinoApp(
        home: CalendarPickerPage(
      earliest: const CalendarMonth(2026, 8),
      latest: const CalendarMonth(2026, 9),
      loadMonth: (month) async {
        loads.add(month);
        return unresolvedMonth(month);
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('calendar-prev-month')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('calendar-next-month')));
    await tester.pumpAndSettle();
    expect(loads, [
      const CalendarMonth(2026, 9),
      const CalendarMonth(2026, 8),
      const CalendarMonth(2026, 9),
    ]);
  });

  testWidgets('repeated date tap only chooses once when no lookup is wired',
      (tester) async {
    var picks = 0;
    await tester.pumpWidget(CupertinoApp(
        home: CalendarPickerPage(
      earliest: const CalendarMonth(2026, 9),
      latest: const CalendarMonth(2026, 9),
      loadMonth: (month) async => unresolvedMonth(month),
      onDateTap: (_) => picks++,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15'));
    await tester.tap(find.text('15'));
    await tester.pump();
    expect(picks, 1);
  });
}
