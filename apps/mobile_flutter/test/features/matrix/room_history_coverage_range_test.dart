import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_history_day_index.dart';
import 'package:liuhetong_mobile/features/matrix/room_history_day_index_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Task A 回归：覆盖区间必须是**有序、互不相邻、不重叠**的区间集合。
///
/// 旧实现把覆盖折叠成单个 `[coveredFrom, coveredTo]` 跨度，于是
/// “1 月 1–5 日” + “1 月 20–25 日” 被错误合并成 “1 月 1–25 日”，
/// 把真正的空档（1 月 6–19 日）谎报为 knownEmpty。
void main() {
  const room = '!room:test';
  DateTime day(int month, int d) => DateTime(2026, month, d);

  group('CoverageRange 值语义', () {
    test('date-only 归一化 + 相等/哈希', () {
      final range = CoverageRange.days(2026, 1, 1, 2026, 1, 5);
      expect(range.startDay, DateTime(2026, 1, 1));
      expect(range.endDay, DateTime(2026, 1, 5));
      expect(range, CoverageRange.days(2026, 1, 1, 2026, 1, 5));
      expect(
          range.hashCode, CoverageRange.days(2026, 1, 1, 2026, 1, 5).hashCode);
      expect(range == CoverageRange.days(2026, 1, 2, 2026, 1, 5), isFalse);
      expect(range.containsDay(DateTime(2026, 1, 3, 23, 59)), isTrue);
      expect(range.containsDay(DateTime(2026, 1, 6)), isFalse);
    });

    test('带时分秒的输入按本地日历日归一化', () {
      final range = CoverageRange(
          DateTime(2026, 1, 1, 23, 59), DateTime(2026, 1, 5, 0, 1));
      expect(range, CoverageRange.days(2026, 1, 1, 2026, 1, 5));
    });
  });

  group('mergeCoverageRanges 纯函数', () {
    test('重叠区间合并 [1,5] + [4,8] -> [1,8]', () {
      expect(
        mergeCoverageRanges([
          CoverageRange.days(2026, 1, 1, 2026, 1, 5),
          CoverageRange.days(2026, 1, 4, 2026, 1, 8),
        ]),
        [CoverageRange.days(2026, 1, 1, 2026, 1, 8)],
      );
    });

    test('相邻区间合并 [1,5] + [6,8] -> [1,8]（日粒度：连续即连续覆盖）', () {
      expect(
        mergeCoverageRanges([
          CoverageRange.days(2026, 1, 1, 2026, 1, 5),
          CoverageRange.days(2026, 1, 6, 2026, 1, 8),
        ]),
        [CoverageRange.days(2026, 1, 1, 2026, 1, 8)],
      );
    });

    test('真实空档绝不合并 [1,5] + [7,8] 保持两段', () {
      expect(
        mergeCoverageRanges([
          CoverageRange.days(2026, 1, 1, 2026, 1, 5),
          CoverageRange.days(2026, 1, 7, 2026, 1, 8),
        ]),
        [
          CoverageRange.days(2026, 1, 1, 2026, 1, 5),
          CoverageRange.days(2026, 1, 7, 2026, 1, 8),
        ],
      );
    });

    test('插入顺序无关（逆序 / 乱序结果一致）', () {
      final a = CoverageRange.days(2026, 1, 1, 2026, 1, 5);
      final b = CoverageRange.days(2026, 1, 20, 2026, 1, 25);
      final c = CoverageRange.days(2026, 2, 2, 2026, 2, 2);
      final d = CoverageRange.days(2026, 1, 6, 2026, 1, 10);
      // [1,5] 与 [6,10] 相邻 → 合并成 [1,10]；[20,25] 与 02-02 之间是真实空档。
      final expected = [
        CoverageRange.days(2026, 1, 1, 2026, 1, 10),
        b,
        c,
      ];
      expect(mergeCoverageRanges([a, b, c, d]), expected);
      expect(mergeCoverageRanges([c, b, a, d]), expected);
      expect(mergeCoverageRanges([d, a, b, c]), expected);
      expect(mergeCoverageRanges([b, c, d, a]), expected);
      expect(mergeCoverageRanges([c, d, b, a]), expected);
    });

    test('重复元素幂等，空输入得到空集合', () {
      final a = CoverageRange.days(2026, 1, 1, 2026, 1, 5);
      expect(mergeCoverageRanges([a, a, a]), [a]);
      expect(mergeCoverageRanges(const []), isEmpty);
      expect(mergeCoverageRanges([a]), [a]);
    });

    test('合并结果自身幂等（再次合并不变）', () {
      final once = mergeCoverageRanges([
        CoverageRange.days(2026, 3, 1, 2026, 3, 5),
        CoverageRange.days(2026, 3, 6, 2026, 3, 9),
        CoverageRange.days(2026, 1, 1, 2026, 1, 2),
      ]);
      expect(mergeCoverageRanges(once), once);
    });
  });

  group('CoverageRangeSet', () {
    test('add 幂等、查询落在真实区间内才为 true', () {
      var set = const CoverageRangeSet();
      expect(set.isEmpty, isTrue);
      set = set.add(CoverageRange.days(2026, 1, 1, 2026, 1, 5));
      set = set.add(CoverageRange.days(2026, 1, 1, 2026, 1, 5));
      expect(set.ranges, [CoverageRange.days(2026, 1, 1, 2026, 1, 5)]);
      expect(set.containsDay(DateTime(2026, 1, 3)), isTrue);
      expect(set.containsDay(DateTime(2026, 1, 6)), isFalse);

      set = set.add(CoverageRange.days(2026, 1, 6, 2026, 1, 8));
      expect(set.ranges, [CoverageRange.days(2026, 1, 1, 2026, 1, 8)],
          reason: '相邻区间必须合并');
    });

    test('序列化 / 反序列化保留空档与顺序', () {
      final set = const CoverageRangeSet()
          .add(CoverageRange.days(2026, 1, 20, 2026, 1, 25))
          .add(CoverageRange.days(2026, 1, 1, 2026, 1, 5));
      final json = set.toJson();
      expect(json, hasLength(2));
      final restored = CoverageRangeSet.fromJson(json);
      expect(restored, set);
      expect(restored.containsDay(DateTime(2026, 1, 10)), isFalse);
      expect(restored.containsDay(DateTime(2026, 1, 22)), isTrue);
    });

    test('反序列化容忍损坏条目（丢弃整条而不是崩溃）', () {
      final jan1 = DateTime(1970, 1, 1);
      final jan2 = DateTime(1970, 1, 2);
      final restored = CoverageRangeSet.fromJson([
        [jan1.millisecondsSinceEpoch, jan2.millisecondsSinceEpoch],
        'garbage',
        [null, 5],
        [jan2.millisecondsSinceEpoch, jan1.millisecondsSinceEpoch],
      ]);
      expect(restored.ranges, [CoverageRange.days(1970, 1, 1, 1970, 1, 2)],
          reason: 'start > end 的坏区间不得进入集合');
    });
  });

  group('RoomHistoryDayIndex：空档不得被填成 knownEmpty', () {
    test('不相交覆盖不填空档（[01-01,01-05] + [01-20,01-25] → 01-10 仍是 unknown）', () {
      final index = RoomHistoryDayIndex();
      index.recordCoverage(room, from: day(1, 1), to: day(1, 5));
      index.recordCoverage(room, from: day(1, 20), to: day(1, 25));

      expect(index.dayState(room, day(1, 3)), RoomHistoryDayState.knownEmpty);
      expect(index.dayState(room, day(1, 10)), RoomHistoryDayState.unknown,
          reason: '真正的空档既没有加载证据，也没有探测结论 → 不得判空');
      expect(index.dayState(room, day(1, 19)), RoomHistoryDayState.unknown);
      expect(index.dayState(room, day(1, 22)), RoomHistoryDayState.knownEmpty);
      expect(index.dayState(room, day(1, 26)), RoomHistoryDayState.unknown);
    });

    test('相邻覆盖合并且不产生假空档', () {
      final index = RoomHistoryDayIndex();
      index.recordCoverage(room, from: day(1, 1), to: day(1, 5));
      index.recordCoverage(room, from: day(1, 6), to: day(1, 8));
      expect(index.coverageRangesFor(room).ranges,
          [CoverageRange.days(2026, 1, 1, 2026, 1, 8)]);
      expect(index.dayState(room, day(1, 6)), RoomHistoryDayState.knownEmpty);
    });

    test('重复的 recordCoverage 与逆序插入结果一致', () {
      final forward = RoomHistoryDayIndex();
      forward.recordCoverage(room, from: day(1, 1), to: day(1, 5));
      forward.recordCoverage(room, from: day(1, 1), to: day(1, 5));
      forward.recordCoverage(room, from: day(1, 20), to: day(1, 25));
      forward.recordCoverage(room, from: day(1, 20), to: day(1, 25));

      final reversed = RoomHistoryDayIndex();
      reversed.recordCoverage(room, from: day(1, 20), to: day(1, 25));
      reversed.recordCoverage(room, from: day(1, 1), to: day(1, 5));
      reversed.recordCoverage(room, from: day(1, 20), to: day(1, 25));
      reversed.recordCoverage(room, from: day(1, 1), to: day(1, 5));

      expect(reversed.toJson(), forward.toJson(), reason: '插入顺序不得改变序列化结果');
    });

    test('to 早于 from 仍然是 no-op', () {
      final index = RoomHistoryDayIndex();
      index.recordCoverage(room, from: day(1, 5), to: day(1, 1));
      expect(index.coverageRangesFor(room).ranges, isEmpty);
      expect(index.dayState(room, day(1, 3)), RoomHistoryDayState.unknown);
    });

    test('多个月份乱序插入 → 结果确定（两种插入顺序序列化一致）', () {
      final ranges = [
        CoverageRange.days(2026, 1, 1, 2026, 1, 5),
        CoverageRange.days(2026, 2, 10, 2026, 2, 12),
        CoverageRange.days(2026, 3, 1, 2026, 3, 31),
        CoverageRange.days(2026, 5, 4, 2026, 5, 4),
        CoverageRange.days(2026, 4, 30, 2026, 5, 5),
      ];
      final ascending = RoomHistoryDayIndex();
      for (final range in ranges) {
        ascending.recordCoverage(room, from: range.startDay, to: range.endDay);
      }
      final shuffled = RoomHistoryDayIndex();
      for (final i in [3, 1, 4, 0, 2]) {
        shuffled.recordCoverage(room,
            from: ranges[i].startDay, to: ranges[i].endDay);
      }
      expect(shuffled.coverageRangesFor(room).ranges,
          ascending.coverageRangesFor(room).ranges);
      expect(ascending.coverageRangesFor(room).ranges, [
        CoverageRange.days(2026, 1, 1, 2026, 1, 5),
        CoverageRange.days(2026, 2, 10, 2026, 2, 12),
        CoverageRange.days(2026, 3, 1, 2026, 3, 31),
        CoverageRange.days(2026, 4, 30, 2026, 5, 5),
      ]);
      expect(shuffled.toJson().toString(), ascending.toJson().toString());
      expect(ascending.dayState(room, DateTime(2026, 2, 20)),
          RoomHistoryDayState.unknown);
      expect(ascending.dayState(room, DateTime(2026, 3, 15)),
          RoomHistoryDayState.knownEmpty);
    });

    test('单日探测只覆盖那一天，不扩张成整月/整段', () {
      final index = RoomHistoryDayIndex();
      index.recordDayProbe(room, day(1, 15),
          present: false, contributeToCoverage: true);
      expect(index.coverageRangesFor(room).ranges,
          [CoverageRange.days(2026, 1, 15, 2026, 1, 15)]);
      expect(index.dayState(room, day(1, 15)), RoomHistoryDayState.knownEmpty);
      for (final other in [day(1, 1), day(1, 14), day(1, 16), day(1, 31)]) {
        expect(index.dayState(room, other), RoomHistoryDayState.unknown,
            reason: '单日探测不得顺带覆盖其他日期');
      }
    });
  });

  group('持久化：ranges 与 schema v2', () {
    test('JSON round-trip 保留空档', () {
      final index = RoomHistoryDayIndex();
      index.recordCoverage(room, from: day(1, 1), to: day(1, 5));
      index.recordCoverage(room, from: day(1, 20), to: day(1, 25));

      final json = index.toJson();
      expect(json['version'], 2);
      expect(json['version'], RoomHistoryDayIndex.schemaVersion);
      final rooms = json['rooms']! as Map<String, Object?>;
      final payload = rooms[room]! as Map<String, Object?>;
      expect(payload.containsKey('from'), isFalse,
          reason: 'v2 不再写单个跨度 from/to');
      expect(payload.containsKey('to'), isFalse);
      final ranges = payload['coverageRanges']! as List<Object?>;
      expect(ranges, hasLength(2));

      final restored = RoomHistoryDayIndex.fromJson(json);
      expect(
          restored.dayState(room, day(1, 3)), RoomHistoryDayState.knownEmpty);
      expect(restored.dayState(room, day(1, 10)), RoomHistoryDayState.unknown,
          reason: '空档在落盘/重载之后必须仍然是 unknown');
      expect(
          restored.dayState(room, day(1, 22)), RoomHistoryDayState.knownEmpty);
      expect(restored.dayState(room, day(1, 26)), RoomHistoryDayState.unknown);
    });

    test('store save/load 保留空档，且裁剪不破坏区间', () async {
      SharedPreferences.setMockInitialValues({});
      final index = RoomHistoryDayIndex();
      index.recordCoverage(room, from: day(1, 1), to: day(1, 5));
      index.recordCoverage(room, from: day(1, 20), to: day(1, 25));
      index.recordVisibleEvents(room, [
        (eventId: r'$anchor', timestamp: day(1, 22)),
      ]);
      await RoomHistoryDayIndexStore.save('@me:test', index);

      final loaded = await RoomHistoryDayIndexStore.load('@me:test');
      expect(loaded.dayState(room, day(1, 10)), RoomHistoryDayState.unknown);
      expect(
          loaded.dayState(room, day(1, 22)), RoomHistoryDayState.knownPresent);
      expect(loaded.coverageRangesFor(room).ranges, [
        CoverageRange.days(2026, 1, 1, 2026, 1, 5),
        CoverageRange.days(2026, 1, 20, 2026, 1, 25),
      ]);
    });

    test('version 1（含 from/to）整体丢弃，不迁移成假跨度', () {
      final legacy = <String, Object?>{
        'version': 1,
        'rooms': {
          room: {
            'created': DateTime(2026, 1, 1).millisecondsSinceEpoch,
            'from': DateTime(2026, 1, 1).millisecondsSinceEpoch,
            'to': DateTime(2026, 1, 25).millisecondsSinceEpoch,
            'days': {RoomHistoryDayIndex.dayKey(day(1, 22)): r'$anchor'},
            'empty': [RoomHistoryDayIndex.dayKey(day(1, 4))],
          },
        },
      };
      final restored = RoomHistoryDayIndex.fromJson(legacy);
      expect(restored.roomCount, 0, reason: 'v1 覆盖语义不可信 → 宁可重建');
      expect(restored.coverageRangesFor(room).ranges, isEmpty);
      expect(restored.dayState(room, day(1, 10)), RoomHistoryDayState.unknown);
      expect(restored.dayState(room, day(1, 22)), RoomHistoryDayState.unknown);
      expect(restored.roomCreatedAt(room), isNull);
      expect(restored.anchorFor(room, day(1, 22)), isNull);
    });

    test('store 遇到 version 1 的裸 payload 也整体丢弃', () async {
      SharedPreferences.setMockInitialValues({
        RoomHistoryDayIndexStore.keyFor('@me:test'):
            '{"version":1,"rooms":{"$room":{"from":1,"to":2,"days":{}}}}',
      });
      final loaded = await RoomHistoryDayIndexStore.load('@me:test');
      expect(loaded.roomCount, 0);
    });

    test('room 上限裁剪保留最新插入的房间且区间完整', () async {
      SharedPreferences.setMockInitialValues({});
      final index = RoomHistoryDayIndex();
      for (var i = 0; i < 305; i++) {
        final id = '!room$i:test';
        index.recordCoverage(id, from: day(1, 1), to: day(1, 5));
        index.recordCoverage(id, from: day(1, 20), to: day(1, 25));
      }
      await RoomHistoryDayIndexStore.save('@me:test', index);
      final loaded = await RoomHistoryDayIndexStore.load('@me:test');
      expect(loaded.roomCount, 300);
      expect(loaded.dayState('!room304:test', day(1, 10)),
          RoomHistoryDayState.unknown,
          reason: '裁剪后区间不得被压成一个跨度');
      expect(loaded.dayState('!room304:test', day(1, 3)),
          RoomHistoryDayState.knownEmpty);
      expect(loaded.dayState('!room304:test', day(1, 22)),
          RoomHistoryDayState.knownEmpty);
      expect(loaded.coverageRangesFor('!room304:test').ranges, [
        CoverageRange.days(2026, 1, 1, 2026, 1, 5),
        CoverageRange.days(2026, 1, 20, 2026, 1, 25),
      ]);
      expect(loaded.dayState('!room5:test', day(1, 3)),
          RoomHistoryDayState.knownEmpty,
          reason: '最新的 300 个房间保留（!room5..!room304）');
      expect(loaded.dayState('!room4:test', day(1, 3)),
          RoomHistoryDayState.unknown,
          reason: '最旧的 5 个房间被裁掉');
    });
  });

  group('anchor 时间戳持久化（A3）', () {
    test('乱序记录 + JSON 往返后，更早的事件仍能替换 anchor', () {
      final index = RoomHistoryDayIndex();
      index.recordVisibleEvents(room, [
        (eventId: r'$noon', timestamp: DateTime(2026, 1, 4, 12)),
        (eventId: r'$evening', timestamp: DateTime(2026, 1, 4, 20)),
      ]);
      expect(index.anchorFor(room, day(1, 4)), r'$noon');

      final restored = RoomHistoryDayIndex.fromJson(index.toJson());
      expect(restored.anchorFor(room, day(1, 4)), r'$noon');

      restored.recordVisibleEvents(room, [
        (eventId: r'$morning', timestamp: DateTime(2026, 1, 4, 7)),
      ]);
      expect(restored.anchorFor(room, day(1, 4)), r'$morning',
          reason: '重载后 anchor 时间戳不得退化成 epoch-1 哨兵值');
      expect(restored.anchorTimestampFor(room, day(1, 4)),
          DateTime(2026, 1, 4, 7));
    });

    test('anchor 时间戳跨 store 往返仍然可用', () async {
      SharedPreferences.setMockInitialValues({});
      final index = RoomHistoryDayIndex();
      index.recordVisibleEvents(room, [
        (eventId: r'$noon', timestamp: DateTime(2026, 1, 4, 12)),
      ]);
      await RoomHistoryDayIndexStore.save('@me:test', index);
      final loaded = await RoomHistoryDayIndexStore.load('@me:test');

      loaded.recordVisibleEvents(room, [
        (eventId: r'$morning', timestamp: DateTime(2026, 1, 4, 7)),
      ]);
      expect(loaded.anchorFor(room, day(1, 4)), r'$morning');
      expect(
          loaded.anchorTimestampFor(room, day(1, 4)), DateTime(2026, 1, 4, 7));
    });

    test('probe 不得用 null anchor 覆盖已有 anchor', () {
      final index = RoomHistoryDayIndex();
      index.recordVisibleEvents(room, [
        (eventId: r'$real', timestamp: DateTime(2026, 1, 4, 9)),
      ]);
      index.recordDayProbe(room, day(1, 4), present: true, anchorEventId: null);
      expect(index.anchorFor(room, day(1, 4)), r'$real');

      final restored = RoomHistoryDayIndex.fromJson(index.toJson());
      restored.recordDayProbe(room, day(1, 4),
          present: true, anchorEventId: null);
      expect(restored.anchorFor(room, day(1, 4)), r'$real');
      expect(restored.anchorTimestampFor(room, day(1, 4)),
          DateTime(2026, 1, 4, 9));
    });

    test('无事件时间的 anchor 不参与排序（哨兵值不得胜过真实时间）', () {
      final index = RoomHistoryDayIndex();
      index.recordDayProbe(room, day(1, 4),
          present: true, anchorEventId: r'$no-time');
      expect(index.anchorFor(room, day(1, 4)), r'$no-time');
      expect(index.anchorTimestampFor(room, day(1, 4)), isNull,
          reason: '未知时间必须以 null 表示，而不是伪造 epoch-1');
    });
  });

  group('未来日期（A4）', () {
    test('未来日期即使落在覆盖区间内也不得判空', () {
      final index = RoomHistoryDayIndex();
      index.recordCoverage(room, from: day(1, 1), to: day(12, 31));
      final now = DateTime(2026, 6, 15, 10);
      expect(index.dayState(room, day(6, 15), now: now),
          RoomHistoryDayState.knownEmpty,
          reason: '今天不算未来');
      expect(index.dayState(room, day(6, 16), now: now),
          RoomHistoryDayState.unknown);
      expect(index.dayState(room, day(9, 1), now: now),
          RoomHistoryDayState.unknown);
      expect(index.dayState(room, day(5, 1), now: now),
          RoomHistoryDayState.knownEmpty,
          reason: '过去的覆盖日期仍然确认空');
    });

    test('未来日期不影响显式探测结论', () {
      final index = RoomHistoryDayIndex();
      index.recordCoverage(room, from: day(1, 1), to: day(1, 1));
      final now = DateTime(2026, 1, 1, 8);
      index.recordDayProbe(room, day(1, 3),
          present: false, contributeToCoverage: false);
      expect(index.dayState(room, day(1, 3), now: now),
          RoomHistoryDayState.knownEmpty,
          reason: '显式探测结论（emptyDays）不受 future 规则影响');
      expect(index.dayState(room, day(1, 4), now: now),
          RoomHistoryDayState.unknown);
    });

    test('未传 now 时保持既有行为（不做 future 判定）', () {
      final index = RoomHistoryDayIndex();
      index.recordCoverage(room, from: day(1, 1), to: day(1, 5));
      expect(index.dayState(room, day(1, 3)), RoomHistoryDayState.knownEmpty);
    });

    test('monthDays 透传 now：未来日期为 unknown 而不是 knownEmpty', () {
      final index = RoomHistoryDayIndex();
      // 覆盖 2026-05-01..2026-06-30（含 6 月 15 日当天），6 月 15 日之后是未来。
      index.recordCoverage('!m:test',
          from: DateTime(2026, 5, 1), to: DateTime(2026, 6, 30));
      final month = index.monthDays('!m:test', const CalendarMonth(2026, 6),
          now: DateTime(2026, 6, 15, 10));
      expect(month.stateOf(10), RoomHistoryDayState.knownEmpty,
          reason: '6 月 10 日在 now 之前 → 覆盖区间内确认空');
      expect(month.stateOf(15), RoomHistoryDayState.knownEmpty,
          reason: '今天不算未来');
      expect(month.stateOf(16), RoomHistoryDayState.unknown,
          reason: '未来日期在覆盖区间内也不得判空');
      expect(month.stateOf(30), RoomHistoryDayState.unknown);
      expect(month.coverageComplete, isFalse);
      expect(month.hasUnknown, isTrue);

      final consistent = index.monthDays(
          '!m:test', const CalendarMonth(2026, 6),
          now: DateTime(2026, 6, 30, 23));
      expect(consistent.stateOf(16), RoomHistoryDayState.knownEmpty);
      expect(consistent.hasUnknown, isFalse);
    });
  });
}
