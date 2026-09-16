import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_media_shared_logic.dart';
import 'package:liuhetong_mobile/ui/chat/chat_search_page.dart';

/// Task A：月历只读 typed 日期 metadata（RoomHistoryMonthDays）。
///
/// 打开/切月都会请求该月 metadata（有界、不加载正文），且：
/// - knownPresent 高亮可点；
/// - knownEmpty 弱化不可点；
/// - unknown 保持可点（点击走该日的有界定位查询）；
/// - 未来日期不可点；
/// - 加载中/失败是独立状态，绝不显示成"本月没有聊天记录"。
void main() {
  RoomHistoryMonthDays month(
    int year,
    int m, {
    Map<int, RoomHistoryDayState> states = const {},
  }) =>
      RoomHistoryMonthDays(
          month: CalendarMonth(year, m), dayStates: states);

  testWidgets('打开时读取当前月 metadata，knownPresent 高亮、knownEmpty 灰显、unknown 可点',
      (tester) async {
    final requested = <CalendarMonth>[];
    DateTime? picked;
    await tester.pumpWidget(CupertinoApp(
      home: CalendarPickerPage(
        earliest: const CalendarMonth(2026, 8),
        latest: const CalendarMonth(2026, 9),
        loadMonth: (m) async {
          requested.add(m);
          return month(m.year, m.month, states: {
            3: RoomHistoryDayState.knownPresent,
            10: RoomHistoryDayState.knownEmpty,
          });
        },
        onDateTap: (date) => picked = date,
      ),
    ));
    await tester.pumpAndSettle();

    expect(requested, [const CalendarMonth(2026, 9)],
        reason: '打开即读取当月 metadata，不需要等待用户操作');

    final present = tester.widget<Container>(find.descendant(
      of: find.byKey(const Key('calendar-day-3')),
      matching: find.byType(Container),
    ));
    expect((present.decoration! as BoxDecoration).color,
        isNotNull, reason: 'knownPresent 有消息标记');

    final empty = tester.widget<Container>(find.descendant(
      of: find.byKey(const Key('calendar-day-10')),
      matching: find.byType(Container),
    ));
    expect((empty.decoration! as BoxDecoration).color, isNull,
        reason: 'knownEmpty 不得高亮');

    // knownEmpty 不可点。
    await tester.tap(find.byKey(const Key('calendar-day-10')));
    await tester.pump();
    expect(picked, isNull);

    // unknown 仍是普通可点日期（可能只是本地没有覆盖证据）。
    await tester.tap(find.byKey(const Key('calendar-day-15')));
    await tester.pump();
    expect(picked, DateTime(2026, 9, 15));
  });

  testWidgets('切月读取新月份并丢弃过期响应', (tester) async {
    final september = Completer<RoomHistoryMonthDays>();
    final august = Completer<RoomHistoryMonthDays>();
    var cancels = 0;
    await tester.pumpWidget(CupertinoApp(
      home: CalendarPickerPage(
        earliest: const CalendarMonth(2026, 8),
        latest: const CalendarMonth(2026, 9),
        onCancelMonthLookup: () => cancels++,
        loadMonth: (m) =>
            m.month == 9 ? september.future : august.future,
      ),
    ));
    await tester.pump();
    expect(find.byKey(const Key('calendar-month-loading')), findsOneWidget);

    await tester.tap(find.byKey(const Key('calendar-prev-month')));
    await tester.pump();
    expect(cancels, 1, reason: '切月必须取消在途月查询');

    august.complete(month(2026, 8, states: {
      15: RoomHistoryDayState.knownPresent,
    }));
    await tester.pump();
    // 过期的 9 月响应不得覆盖 8 月状态。
    september.complete(month(2026, 9, states: {
      1: RoomHistoryDayState.knownPresent,
    }));
    await tester.pumpAndSettle();

    final marker = tester.widget<Container>(find.descendant(
      of: find.byKey(const Key('calendar-day-15')),
      matching: find.byType(Container),
    ));
    expect((marker.decoration! as BoxDecoration).color, isNotNull);
    expect(find.text('2026年8月'), findsOneWidget);
  });

  testWidgets('加载中与失败都不冒充"本月没有聊天记录"，失败可重试', (tester) async {
    var calls = 0;
    RoomHistoryMonthDays coveredEmptyMonth(CalendarMonth m) =>
        RoomHistoryMonthDays(
          month: m,
          dayStates: {
            for (var day = 1; day <= m.daysInMonth; day++)
              day: RoomHistoryDayState.knownEmpty,
          },
          coverageComplete: true,
        );
    await tester.pumpWidget(CupertinoApp(
      home: CalendarPickerPage(
        latest: const CalendarMonth(2026, 9),
        loadMonth: (m) async {
          calls++;
          if (calls == 1) throw StateError('offline');
          return coveredEmptyMonth(m);
        },
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendar-month-error')), findsOneWidget);
    expect(find.byKey(const Key('calendar-month-empty')), findsNothing,
        reason: '查询失败 ≠ 确认无记录');

    await tester.tap(find.byKey(const Key('calendar-month-error')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byKey(const Key('calendar-month-empty')), findsOneWidget,
        reason: '整月已覆盖且无消息才提示本月无记录');
  });

  testWidgets('覆盖不足的月份不显示"本月没有聊天记录"', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: CalendarPickerPage(
        latest: const CalendarMonth(2026, 9),
        loadMonth: (_) async => RoomHistoryMonthDays(
          month: const CalendarMonth(2026, 9),
          dayStates: const {3: RoomHistoryDayState.knownPresent},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendar-month-empty')), findsNothing);
  });

  testWidgets('未来日期始终不可点，即使 metadata 标记为有消息', (tester) async {
    final future = DateTime.now().add(const Duration(days: 2));
    DateTime? picked;
    await tester.pumpWidget(CupertinoApp(
      home: CalendarPickerPage(
        earliest: CalendarMonth(future.year, future.month),
        latest: CalendarMonth(future.year, future.month),
        loadMonth: (m) async => month(m.year, m.month, states: {
          future.day: RoomHistoryDayState.knownPresent,
        }),
        onDateTap: (date) => picked = date,
      ),
    ));
    await tester.pumpAndSettle();

    final day = find.byKey(Key('calendar-day-${future.day}'));
    await tester.tap(day);
    await tester.pump();
    expect(picked, isNull);
    final cell = tester.widget<Container>(
        find.descendant(of: day, matching: find.byType(Container)));
    expect((cell.decoration! as BoxDecoration).color, isNull,
        reason: '未来日期不得显示消息标记');
  });

  testWidgets('最早月份未知时仍可向前翻月（不回退到 1970）', (tester) async {
    final requested = <CalendarMonth>[];
    await tester.pumpWidget(CupertinoApp(
      home: CalendarPickerPage(
        latest: const CalendarMonth(2026, 9),
        loadMonth: (m) async {
          requested.add(m);
          return month(m.year, m.month);
        },
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('calendar-prev-month')));
    await tester.pumpAndSettle();
    expect(requested,
        [const CalendarMonth(2026, 9), const CalendarMonth(2026, 8)]);
    expect(find.text('2026年8月'), findsOneWidget);
  });

  testWidgets('导航钳制：不得越过最早/最新月份', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: CalendarPickerPage(
        earliest: const CalendarMonth(2026, 9),
        latest: const CalendarMonth(2026, 9),
        loadMonth: (m) async => month(m.year, m.month),
      ),
    ));
    await tester.pumpAndSettle();
    final prev = tester.widget<CupertinoButton>(
        find.byKey(const Key('calendar-prev-month')));
    final next = tester.widget<CupertinoButton>(
        find.byKey(const Key('calendar-next-month')));
    expect(prev.onPressed, isNull);
    expect(next.onPressed, isNull);
  });

  testWidgets('关闭月历时取消在途查询', (tester) async {
    var cancels = 0;
    final pending = Completer<RoomHistoryMonthDays>();
    await tester.pumpWidget(CupertinoApp(
      home: CalendarPickerPage(
        latest: const CalendarMonth(2026, 9),
        onCancelMonthLookup: () => cancels++,
        loadMonth: (_) => pending.future,
      ),
    ));
    await tester.pump();
    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(cancels, 1);
  });
}
