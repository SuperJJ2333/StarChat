import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_history_day_index.dart';
import 'package:liuhetong_mobile/features/matrix/room_history_day_index_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Task A：日期 metadata 索引（**只存日期状态**，不存正文/媒体）。
void main() {
  const room = '!room:test';

  group('CalendarMonth', () {
    test('月导航、标题、天数与周一开头', () {
      const m = CalendarMonth(2026, 9);
      expect(m.key, '2026-09');
      expect(m.title, '2026年9月');
      expect(m.daysInMonth, 30);
      expect(m.previous, const CalendarMonth(2026, 8));
      expect(m.next, const CalendarMonth(2026, 10));
      expect(m.firstWeekdayMondayBased, DateTime(2026, 9, 1).weekday);
      expect(m.contains(DateTime(2026, 9, 30, 23, 59)), isTrue);
      expect(m.contains(DateTime(2026, 10, 1)), isFalse);
      expect(const CalendarMonth(2026, 2).daysInMonth, 28);
      expect(const CalendarMonth(2024, 2).daysInMonth, 29,
          reason: '闰年不得算错');
      expect(CalendarMonth.of(DateTime(2026, 9, 17)), const CalendarMonth(2026, 9));
      expect(const CalendarMonth(2026, 9).compareTo(const CalendarMonth(2026, 8)),
          1);
    });
  });

  group('RoomHistoryDayIndex 状态判定', () {
    test('本地没有这一天 ≠ 这一天没有消息（unknown 而不是空）', () {
      final index = RoomHistoryDayIndex();
      expect(index.dayState(room, DateTime(2026, 9, 3)),
          RoomHistoryDayState.unknown);
      expect(index.anchorFor(room, DateTime(2026, 9, 3)), isNull);
    });

    test('可见事件 → knownPresent + 当天最早事件作为 anchor', () {
      final index = RoomHistoryDayIndex();
      index.recordVisibleEvents(room, [
        (eventId: r'$late', timestamp: DateTime(2026, 9, 3, 20)),
        (eventId: r'$early', timestamp: DateTime(2026, 9, 3, 8)),
        (eventId: r'$other', timestamp: DateTime(2026, 9, 4, 9)),
      ]);
      expect(index.dayState(room, DateTime(2026, 9, 3, 23)),
          RoomHistoryDayState.knownPresent);
      expect(index.anchorFor(room, DateTime(2026, 9, 3)), r'$early');
      expect(index.anchorFor(room, DateTime(2026, 9, 4)), r'$other');
    });

    test('早于房间创建时间的日期可确认为空，创建当天不算空', () {
      final index = RoomHistoryDayIndex();
      index.recordRoomCreatedAt(room, DateTime(2026, 9, 10, 15, 30));
      expect(index.dayState(room, DateTime(2026, 9, 10)),
          RoomHistoryDayState.unknown,
          reason: '创建当天不能判定为空（可能还没开始聊天或已有消息）');
      expect(index.dayState(room, DateTime(2026, 9, 9)),
          RoomHistoryDayState.knownEmpty);
      expect(index.roomCreatedAt(room), DateTime(2026, 9, 10));
    });

    test('连续覆盖区间内无事件 → knownEmpty；区间外 → unknown', () {
      final index = RoomHistoryDayIndex();
      index.recordCoverage(room,
          from: DateTime(2026, 9, 5, 9), to: DateTime(2026, 9, 8, 22));
      expect(index.dayState(room, DateTime(2026, 9, 6)),
          RoomHistoryDayState.knownEmpty);
      expect(index.dayState(room, DateTime(2026, 9, 4)),
          RoomHistoryDayState.unknown);
      expect(index.dayState(room, DateTime(2026, 9, 9)),
          RoomHistoryDayState.unknown);
    });

    test('显式探测结论覆盖推断：present 与 empty 都可记录', () {
      final index = RoomHistoryDayIndex();
      index.recordDayProbe(room, DateTime(2026, 9, 20), present: false);
      expect(index.dayState(room, DateTime(2026, 9, 20)),
          RoomHistoryDayState.knownEmpty);
      index.recordDayProbe(room, DateTime(2026, 9, 20),
          present: true, anchorEventId: r'$probe');
      expect(index.dayState(room, DateTime(2026, 9, 20)),
          RoomHistoryDayState.knownPresent);
      expect(index.anchorFor(room, DateTime(2026, 9, 20)), r'$probe');
    });

    test('earliestKnownDay 只按“有消息”的日期计算（避免 1970 假日期）', () {
      final index = RoomHistoryDayIndex();
      expect(index.earliestKnownDay(room), isNull);
      index.recordRoomCreatedAt(room, DateTime(2026, 1, 1));
      index.recordCoverage(room,
          from: DateTime(2026, 1, 1), to: DateTime(2026, 1, 31));
      expect(index.earliestKnownDay(room), isNull,
          reason: '创建时间与覆盖区间都不是“有消息”的证据');
      index.recordVisibleEvents(room, [
        (eventId: r'$m', timestamp: DateTime(2026, 5, 4, 10)),
      ]);
      expect(index.earliestKnownDay(room), DateTime(2026, 5, 4));
    });

    test('月级 metadata 只返回日期状态与 anchor，CoverageComplete 反映覆盖', () {
      final index = RoomHistoryDayIndex();
      index.recordRoomCreatedAt(room, DateTime(2026, 9, 5));
      index.recordVisibleEvents(room, [
        (eventId: r'$a', timestamp: DateTime(2026, 9, 12, 10)),
      ]);
      final days = index.monthDays(room, const CalendarMonth(2026, 9));
      expect(days.month, const CalendarMonth(2026, 9));
      expect(days.stateOf(12), RoomHistoryDayState.knownPresent);
      expect(days.anchors[12], r'$a');
      expect(days.stateOf(4), RoomHistoryDayState.knownEmpty,
          reason: '早于创建时间的日期可确认为空');
      expect(days.stateOf(6), RoomHistoryDayState.unknown,
          reason: '创建之后没有覆盖证据 → unknown');
      expect(days.hasUnknown, isTrue);
      expect(days.presentDates, {DateTime(2026, 9, 12)});
      expect(days.unknownDates, contains(DateTime(2026, 9, 13)));
    });

    test('未记录房间的月份全部为 unknown，而不是空月', () {
      final days = RoomHistoryDayIndex()
          .monthDays('!unknown:test', const CalendarMonth(2026, 9));
      expect(days.dayStates, isEmpty);
      expect(days.stateOf(1), RoomHistoryDayState.unknown);
      expect(days.coverageComplete, isFalse);
      expect(days.hasUnknown, isTrue);
    });

    test('clearRoom / clear 只移除 metadata', () {
      final index = RoomHistoryDayIndex();
      index.recordVisibleEvents(room, [
        (eventId: r'$a', timestamp: DateTime(2026, 9, 12, 10)),
      ]);
      index.clearRoom(room);
      expect(index.dayState(room, DateTime(2026, 9, 12)),
          RoomHistoryDayState.unknown);
      index.recordVisibleEvents(room, [
        (eventId: r'$b', timestamp: DateTime(2026, 9, 13, 10)),
      ]);
      index.clear();
      expect(index.roomCount, 0);
    });
  });

  group('persistence', () {
    test('JSON round-trip 保留状态、anchor、覆盖与创建时间', () {
      final index = RoomHistoryDayIndex();
      index.recordRoomCreatedAt(room, DateTime(2026, 1, 1));
      index.recordCoverage(room,
          from: DateTime(2026, 2, 1), to: DateTime(2026, 2, 3));
      index.recordVisibleEvents(room, [
        (eventId: r'$anchor', timestamp: DateTime(2026, 2, 2, 9)),
      ]);
      index.recordDayProbe(room, DateTime(2026, 2, 5), present: false);

      final restored = RoomHistoryDayIndex.fromJson(index.toJson());
      expect(restored.toJson()['version'], RoomHistoryDayIndex.schemaVersion);
      expect(restored.dayState(room, DateTime(2026, 2, 2)),
          RoomHistoryDayState.knownPresent);
      expect(restored.anchorFor(room, DateTime(2026, 2, 2)), r'$anchor');
      expect(restored.dayState(room, DateTime(2026, 2, 5)),
          RoomHistoryDayState.knownEmpty);
      expect(restored.dayState(room, DateTime(2026, 2, 3)),
          RoomHistoryDayState.knownEmpty,
          reason: '覆盖区间内无事件 → 确认空');
      expect(restored.dayState(room, DateTime(2026, 3, 1)),
          RoomHistoryDayState.unknown,
          reason: '未覆盖的日期不得变成空');
      expect(restored.roomCreatedAt(room), DateTime(2026, 1, 1));
    });

    test('schema 版本不匹配时整体丢弃重建（不猜测旧格式）', () {
      final index = RoomHistoryDayIndex();
      index.recordVisibleEvents(room, [
        (eventId: r'$anchor', timestamp: DateTime(2026, 2, 2, 9)),
      ]);
      final json = index.toJson()..['version'] = 999;
      final restored = RoomHistoryDayIndex.fromJson(json);
      expect(restored.roomCount, 0);
    });

    test('JSON 中不含任何消息正文/媒体字段', () {
      final index = RoomHistoryDayIndex();
      index.recordVisibleEvents(room, [
        (eventId: r'$anchor', timestamp: DateTime(2026, 2, 2, 9)),
      ]);
      final encoded = index.toJson().toString();
      expect(encoded, contains(r'$anchor'));
      for (final forbidden in ['body', 'plaintext', 'mxc://', 'accessToken']) {
        expect(encoded, isNot(contains(forbidden)));
      }
    });

    test('store round-trip（account scoped，仅 metadata）', () async {
      SharedPreferences.setMockInitialValues({});
      final index = RoomHistoryDayIndex();
      index.recordVisibleEvents(room, [
        (eventId: r'$anchor', timestamp: DateTime(2026, 3, 4, 9)),
      ]);
      await RoomHistoryDayIndexStore.save('@me:test', index);
      final loaded = await RoomHistoryDayIndexStore.load('@me:test');
      expect(loaded.dayState(room, DateTime(2026, 3, 4)),
          RoomHistoryDayState.knownPresent);
      expect(loaded.anchorFor(room, DateTime(2026, 3, 4)), r'$anchor');

      final otherAccount = await RoomHistoryDayIndexStore.load('@other:test');
      expect(otherAccount.roomCount, 0, reason: '账号之间必须隔离');

      await RoomHistoryDayIndexStore.clear('@me:test');
      final cleared = await RoomHistoryDayIndexStore.load('@me:test');
      expect(cleared.roomCount, 0);
    });

    test('损坏的持久化内容退化为空索引而不是抛错', () async {
      SharedPreferences.setMockInitialValues({
        RoomHistoryDayIndexStore.keyFor('@me:test'): '{not json',
      });
      final loaded = await RoomHistoryDayIndexStore.load('@me:test');
      expect(loaded.roomCount, 0);
    });
  });
}
