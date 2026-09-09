import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/chat_search_page.dart';
import 'package:liuhetong_mobile/features/matrix/chat_media_shared_logic.dart';

void main() {
  testWidgets(
      'previous month loads real history and ignores stale month response',
      (tester) async {
    final september = Completer<Set<DateTime>>();
    final august = Completer<Set<DateTime>>();
    DateTime? picked;
    await tester.pumpWidget(CupertinoApp(
        home: CalendarPickerPage(
      earliest: const CalendarMonth(2026, 8),
      latest: const CalendarMonth(2026, 9),
      loadMonth: (month) => month.month == 9 ? september.future : august.future,
      onDateTap: (date) => picked = date,
    )));
    await tester.tap(find.byKey(const Key('calendar-prev-month')));
    await tester.pump();
    august.complete({DateTime(2026, 8, 15)});
    await tester.pump();
    september.complete({DateTime(2026, 9, 1)});
    await tester.pump();
    await tester.tap(find.text('15'));
    await tester.pump();
    expect(picked, DateTime(2026, 8, 15));
  });

  testWidgets(
      'empty month is explicit, failures retry, repeated date tap only chooses once',
      (tester) async {
    var calls = 0;
    var picks = 0;
    await tester.pumpWidget(CupertinoApp(
        home: CalendarPickerPage(
      earliest: const CalendarMonth(2026, 9),
      latest: const CalendarMonth(2026, 9),
      loadMonth: (_) async {
        if (++calls == 1) throw StateError('offline');
        return {};
      },
      onDateTap: (_) => picks++,
    )));
    await tester.pump();
    expect(find.text('历史加载失败，点击重试'), findsOneWidget);
    await tester.tap(find.text('历史加载失败，点击重试'));
    await tester.pumpAndSettle();
    expect(find.text('本月暂无聊天记录'), findsOneWidget);
    await tester.tap(find.text('15'));
    expect(picks, 0);
  });
}
