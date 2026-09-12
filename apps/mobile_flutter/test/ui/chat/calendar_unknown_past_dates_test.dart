import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_media_shared_logic.dart';
import 'package:liuhetong_mobile/ui/chat/chat_search_page.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';

void main() {
  testWidgets('metadata-only calendar never requests a month on open or change',
      (tester) async {
    var loads = 0;
    await tester.pumpWidget(CupertinoApp(
      home: CalendarPickerPage(
        earliest: const CalendarMonth(2026, 8),
        latest: const CalendarMonth(2026, 9),
        allowUnknownPastDates: true,
        loadMonth: (_) {
          loads++;
          return Completer<Set<DateTime>>().future;
        },
      ),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const Key('calendar-prev-month')));
    await tester.pump();

    expect(loads, 0);
    expect(find.text('尚未加载聊天记录，可选择日期查询'), findsOneWidget);
  });

  testWidgets('unknown past date is selectable, a future date remains disabled',
      (tester) async {
    final now = DateTime.now();
    final past = now.subtract(const Duration(days: 2));
    final future = now.add(const Duration(days: 2));
    DateTime? picked;
    await tester.pumpWidget(CupertinoApp(
      home: CalendarPickerPage(
        earliest: CalendarMonth(past.year, past.month),
        latest: CalendarMonth(future.year, future.month),
        allowUnknownPastDates: true,
        onDateTap: (date) => picked = date,
      ),
    ));
    await tester.pump();
    if (past.month != future.month) {
      await tester.tap(find.byKey(const Key('calendar-prev-month')));
      await tester.pump();
    }
    await tester.tap(find.byKey(Key('calendar-day-${past.day}')));
    expect(picked, DateTime(past.year, past.month, past.day));

    picked = null;
    await tester.pumpWidget(CupertinoApp(
      home: CalendarPickerPage(
        key: const ValueKey('future-calendar'),
        earliest: CalendarMonth(future.year, future.month),
        latest: CalendarMonth(future.year, future.month),
        allowUnknownPastDates: true,
        onDateTap: (date) => picked = date,
      ),
    ));
    await tester.pump();
    await tester.tap(find.byKey(Key('calendar-day-${future.day}')));
    expect(picked, isNull);
  });

  testWidgets('known dates retain their green message marker', (tester) async {
    final known = DateTime(2026, 9, 3);
    await tester.pumpWidget(CupertinoApp(
      home: CalendarPickerPage(
        earliest: const CalendarMonth(2026, 9),
        latest: const CalendarMonth(2026, 9),
        allowUnknownPastDates: true,
        datesWithMessages: {known},
      ),
    ));
    await tester.pump();

    final marker = tester.widget<Container>(find.descendant(
      of: find.byKey(const Key('calendar-day-3')),
      matching: find.byType(Container),
    ));
    final decoration = marker.decoration! as BoxDecoration;
    expect(decoration.color, WeChatColors.brandPrimary.withValues(alpha: .12));
  });

  testWidgets('a known future date is disabled and has no green marker',
      (tester) async {
    final future = DateTime.now().add(const Duration(days: 2));
    DateTime? picked;
    await tester.pumpWidget(CupertinoApp(
      home: CalendarPickerPage(
        earliest: CalendarMonth(future.year, future.month),
        latest: CalendarMonth(future.year, future.month),
        allowUnknownPastDates: true,
        datesWithMessages: {DateTime(future.year, future.month, future.day)},
        onDateTap: (date) => picked = date,
      ),
    ));
    await tester.pump();

    final day = find.byKey(Key('calendar-day-${future.day}'));
    await tester.tap(day);
    expect(picked, isNull);
    final marker = tester.widget<Container>(
        find.descendant(of: day, matching: find.byType(Container)));
    expect((marker.decoration! as BoxDecoration).color, isNull);
  });
}
