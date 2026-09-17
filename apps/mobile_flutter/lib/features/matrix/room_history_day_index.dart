import 'package:flutter/foundation.dart';

/// 日历月（本地时区）。
@immutable
final class CalendarMonth implements Comparable<CalendarMonth> {
  const CalendarMonth(this.year, this.month);

  factory CalendarMonth.of(DateTime date) =>
      CalendarMonth(date.year, date.month);

  final int year;
  final int month;

  int get daysInMonth => DateTime(year, month + 1, 0).day;
  String get key => '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}';
  String get title => '$year年$month月';
  DateTime get firstDay => DateTime(year, month, 1);
  DateTime get lastDay => DateTime(year, month, daysInMonth);

  /// 该月 1 号是周几（1=周一 … 7=周日；月历按周一开头）。
  int get firstWeekdayMondayBased => DateTime(year, month, 1).weekday;

  bool contains(DateTime date) => date.year == year && date.month == month;
  bool containsDay(DateTime day) => contains(day);

  /// 月份导航范围限制：最早与最新可访问月份之间。
  bool canNavigateTo(CalendarMonth target,
          {required CalendarMonth earliest, required CalendarMonth latest}) =>
      !(target.year < earliest.year ||
          (target.year == earliest.year && target.month < earliest.month) ||
          target.year > latest.year ||
          (target.year == latest.year && target.month > latest.month));

  CalendarMonth get previous =>
      month == 1 ? CalendarMonth(year - 1, 12) : CalendarMonth(year, month - 1);
  CalendarMonth get next =>
      month == 12 ? CalendarMonth(year + 1, 1) : CalendarMonth(year, month + 1);

  @override
  int compareTo(CalendarMonth other) => year == other.year
      ? month.compareTo(other.month)
      : year.compareTo(other.year);

  @override
  bool operator ==(Object other) =>
      other is CalendarMonth && other.year == year && other.month == month;

  @override
  int get hashCode => Object.hash(year, month);

  @override
  String toString() => key;
}

/// 单个“已覆盖”日历日区间，闭区间 `[startDay, endDay]`，**日粒度、本地时区**。
///
/// startDay/endDay 一定是 date-only（`00:00` 本地时间）；构造时会把带时分秒的
/// 时间戳归一化成它所属的本地日历日，因此“同一天的任何时刻”都只产生一个日期。
/// [CoverageRange] 只表达连续覆盖事实，不表达“有消息”或“无消息”。
@immutable
final class CoverageRange {
  /// 从时间戳构造：两端都归一化成各自所属的本地日历日（date-only）。
  factory CoverageRange(DateTime start, DateTime end) =>
      CoverageRange._(_dateOnly(start), _dateOnly(end));

  /// 从日历日构造（`CoverageRange(2026, 1, 1, 2026, 1, 5)`）。
  factory CoverageRange.days(int startYear, int startMonth, int startDay,
          int endYear, int endMonth, int endDay) =>
      CoverageRange._(DateTime(startYear, startMonth, startDay),
          DateTime(endYear, endMonth, endDay));

  /// alias of [CoverageRange]，便于调用点自解释。
  factory CoverageRange.from(DateTime start, DateTime end) =>
      CoverageRange(start, end);

  const CoverageRange._(this.startDay, this.endDay);

  final DateTime startDay;
  final DateTime endDay;

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  bool containsDay(DateTime day) {
    final date = _dateOnly(day);
    return !date.isBefore(startDay) && !date.isAfter(endDay);
  }

  /// 是否与 [other] 重叠**或相邻**（日粒度下连续两天即连续覆盖）。
  bool touches(CoverageRange other) =>
      CoverageRange._touches(startDay, endDay, other.startDay, other.endDay);

  static bool _touches(
          DateTime aStart, DateTime aEnd, DateTime bStart, DateTime bEnd) =>
      !bStart.isAfter(aEnd.add(const Duration(days: 1))) &&
      !aStart.isAfter(bEnd.add(const Duration(days: 1)));

  @override
  bool operator ==(Object other) =>
      other is CoverageRange &&
      other.startDay == startDay &&
      other.endDay == endDay;

  @override
  int get hashCode => Object.hash(startDay, endDay);

  @override
  String toString() => 'CoverageRange(${_key(startDay)}..${_key(endDay)})';

  static String _key(DateTime day) => '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';
}

/// 纯函数：把任意顺序的区间列表归一化成**有序、互不重叠、互不相邻**的区间列表。
///
/// 只做三件事：按开始日排序 → 重叠或相邻（日粒度连续）则合并 → 丢弃 `start > end`
/// 的坏区间。**存在真实空档的区间绝不合并**（`[1,5] + [7,8]` 保持两段）。
/// 结果与插入顺序无关，且对结果再次调用是幂等的（`merge(merge(x)) == merge(x)`）。
List<CoverageRange> mergeCoverageRanges(Iterable<CoverageRange> ranges) {
  final sorted = ranges
      .where((range) => !range.endDay.isBefore(range.startDay))
      .toList(growable: false)
    ..sort((a, b) {
      final byStart = a.startDay.compareTo(b.startDay);
      return byStart != 0 ? byStart : a.endDay.compareTo(b.endDay);
    });
  if (sorted.isEmpty) return const <CoverageRange>[];
  final merged = <CoverageRange>[];
  var currentStart = sorted.first.startDay;
  var currentEnd = sorted.first.endDay;
  for (var i = 1; i < sorted.length; i++) {
    final range = sorted[i];
    // 相邻（end + 1 天 == start）同样属于连续覆盖，必须合并。
    if (!range.startDay.isAfter(currentEnd.add(const Duration(days: 1)))) {
      if (range.endDay.isAfter(currentEnd)) currentEnd = range.endDay;
      continue;
    }
    merged.add(CoverageRange._(currentStart, currentEnd));
    currentStart = range.startDay;
    currentEnd = range.endDay;
  }
  merged.add(CoverageRange._(currentStart, currentEnd));
  return List<CoverageRange>.unmodifiable(merged);
}

/// 不可变的覆盖区间集合：始终持有 [mergeCoverageRanges] 归一化后的区间。
///
/// 语义边界：一个日期只有**落在某个真实区间内**才算“已被加载覆盖”；
/// 落在区间之间的空档里仍然是未知，绝不能因为“两侧都覆盖了”就判空。
@immutable
final class CoverageRangeSet {
  const CoverageRangeSet() : _ranges = const <CoverageRange>[];

  const CoverageRangeSet._(this._ranges);

  /// 从任意区间列表构造（自动合并重叠/相邻区间）。
  factory CoverageRangeSet.of(Iterable<CoverageRange> ranges) =>
      CoverageRangeSet._(mergeCoverageRanges(ranges));

  final List<CoverageRange> _ranges;

  /// 归一化后的区间（有序、互不重叠、互不相邻）。
  List<CoverageRange> get ranges => _ranges;

  bool get isEmpty => _ranges.isEmpty;
  bool get isNotEmpty => _ranges.isNotEmpty;

  /// 加入一个区间，返回新的集合（不修改自身）。
  CoverageRangeSet add(CoverageRange range) =>
      CoverageRangeSet._(mergeCoverageRanges([..._ranges, range]));

  CoverageRangeSet addAll(Iterable<CoverageRange> ranges) =>
      CoverageRangeSet._(mergeCoverageRanges([..._ranges, ...ranges]));

  /// 该日期是否落在某个真实区间内（区间之间的空档返回 false）。
  bool containsDay(DateTime day) {
    for (final range in _ranges) {
      if (range.containsDay(day)) return true;
    }
    return false;
  }

  /// 持久化格式：`[[startMs, endMs], ...]`（date-only 本地时间的毫秒）。
  List<Object?> toJson() => [
        for (final range in _ranges)
          [
            range.startDay.millisecondsSinceEpoch,
            range.endDay.millisecondsSinceEpoch
          ],
      ];

  /// 反序列化；损坏条目（格式不对 / start > end）整条丢弃，不猜测修补。
  static CoverageRangeSet fromJson(Object? json) {
    if (json is! List) return const CoverageRangeSet();
    final ranges = <CoverageRange>[];
    for (final entry in json) {
      if (entry is! List || entry.length < 2) continue;
      final start = entry[0];
      final end = entry[1];
      if (start is! int || end is! int) continue;
      final range = CoverageRange(DateTime.fromMillisecondsSinceEpoch(start),
          DateTime.fromMillisecondsSinceEpoch(end));
      if (range.endDay.isBefore(range.startDay)) continue;
      ranges.add(range);
    }
    return CoverageRangeSet.of(ranges);
  }

  @override
  bool operator ==(Object other) {
    if (other is! CoverageRangeSet) return false;
    if (other._ranges.length != _ranges.length) return false;
    for (var i = 0; i < _ranges.length; i++) {
      if (other._ranges[i] != _ranges[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_ranges);

  @override
  String toString() => 'CoverageRangeSet($_ranges)';
}

/// 单日状态（禁止再用简单 bool）：
/// - [knownPresent]：已确认该日存在至少一条用户可见消息；
/// - [knownEmpty]：已有足够历史覆盖，可确认当天没有可显示消息；
/// - [unknown]：覆盖不足，**不能**判定为空；
/// - [loading] / [error]：该日的 metadata 正在查询/查询失败。
enum RoomHistoryDayState { knownPresent, knownEmpty, unknown, loading, error }

/// 月级 metadata 查询结果（typed；不含任何聊天正文）。
@immutable
final class RoomHistoryMonthDays {
  const RoomHistoryMonthDays({
    required this.month,
    this.dayStates = const {},
    this.anchors = const {},
    this.coverageComplete = false,
    this.earliestDay,
    this.error,
  });

  final CalendarMonth month;
  final Map<int, RoomHistoryDayState> dayStates;

  /// day → anchorEventId（knownPresent 时可用，避免重复 getEventByTimestamp）。
  final Map<int, String> anchors;

  /// 该月是否已有完整覆盖（可信任 knownEmpty 判定）。
  final bool coverageComplete;
  final DateTime? earliestDay;
  final Object? error;

  RoomHistoryDayState stateOf(int day) =>
      dayStates[day] ?? RoomHistoryDayState.unknown;

  Set<DateTime> get presentDates => {
        for (final entry in dayStates.entries)
          if (entry.value == RoomHistoryDayState.knownPresent)
            DateTime(month.year, month.month, entry.key),
      };

  Set<DateTime> get emptyDates => {
        for (final entry in dayStates.entries)
          if (entry.value == RoomHistoryDayState.knownEmpty)
            DateTime(month.year, month.month, entry.key),
      };

  Set<DateTime> get unknownDates => {
        for (var day = 1; day <= month.daysInMonth; day++)
          if (stateOf(day) == RoomHistoryDayState.unknown)
            DateTime(month.year, month.month, day),
      };

  bool get hasUnknown => unknownDates.isNotEmpty;
}

/// 房间历史日期索引（**metadata only**，account + room scoped）。
///
/// 只保存：roomId、本地日历日、时间边界、是否存在用户可见消息、可选
/// anchorEventId、覆盖状态与 schema 版本。**不保存任何聊天正文/媒体/成员**，
/// 不写入 Business API，也不参与 E2EE 密钥。
///
/// 判定规则（禁止“本地没有这一天 ⇒ 这一天没有消息”）：
/// - 有可见事件 → knownPresent（带 anchor）；
/// - 落在**某个真实覆盖区间内**且无事件 → knownEmpty；
/// - 早于房间创建时间 → knownEmpty；
/// - 显式探测为空的日期（emptyDays）→ knownEmpty；
/// - 其余（含覆盖区间之间的空档、`now` 之后的未来日期）→ unknown。
///
/// 覆盖不再折叠成单个跨度：`[01-01, 01-05] + [01-20, 01-25]` 会保持两段，
/// 中间的空档（01-06..01-19）绝不被谎报为 knownEmpty。
final class RoomHistoryDayIndex {
  RoomHistoryDayIndex();

  /// schema/version metadata（持久化时必须携带，便于未来迁移）。
  ///
  /// v1 → v2：覆盖从单个 `from`/`to` 跨度改为 `coverageRanges` 区间列表。
  /// v1 的覆盖语义（可能把空档吞进跨度）不可信，因此 v1 payload 整体丢弃重建。
  static const schemaVersion = 2;

  /// 房间插入顺序（用于持久化裁剪时保留最近使用的房间）。
  final Map<String, _RoomSlot> _rooms = {};
  var _nextSequence = 0;

  @visibleForTesting
  int get roomCount => _rooms.length;

  static String dayKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  _RoomDayIndex _room(String roomId) => _rooms
      .putIfAbsent(roomId, () => _RoomSlot(_RoomDayIndex(), _nextSequence++))
      .room;

  /// 记录房间真实创建时间（m.room.create）：早于它的日期可确认无消息。
  void recordRoomCreatedAt(String roomId, DateTime? createdAt) {
    if (createdAt == null) return;
    _room(roomId).createdAt = _dateOnly(createdAt);
  }

  /// 记录本机已解密、用户可见的事件（只留日期 + 当天最早事件作为 anchor）。
  ///
  /// anchor 始终指向“当天已知最早的事件”：只有在事件时间戳确实更早时替换；
  /// 未知/缺失的 firstSeenAt 视为“没有更早的证据”，任何真实时间戳都能取代它。
  void recordVisibleEvents(
      String roomId, Iterable<({String eventId, DateTime timestamp})> events) {
    final room = _room(roomId);
    for (final event in events) {
      if (event.eventId.isEmpty) continue;
      final day = _dateOnly(event.timestamp);
      final key = dayKey(day);
      final existing = room.days[key];
      if (existing == null) {
        room.days[key] = _DayEntry(
            anchorEventId: event.eventId, firstSeenAt: event.timestamp);
      } else if (_isEarlier(event.timestamp, existing.firstSeenAt)) {
        room.days[key] = _DayEntry(
            anchorEventId: event.eventId, firstSeenAt: event.timestamp);
      }
    }
  }

  /// [candidate] 是否确实早于 [reference]；[reference] 未知（null）时视为可替换。
  static bool _isEarlier(DateTime? candidate, DateTime? reference) {
    if (candidate == null) return false;
    if (reference == null) return true;
    return candidate.isBefore(reference);
  }

  /// 记录一段“本机确实加载过”的连续覆盖区间。
  ///
  /// 语义：`[from, to]` 内**本机已经取到了完整时间窗**，因此区间内没有可见事件的
  /// 日期可以判定为空。区间只是**追加**到覆盖集合里（重叠/相邻自动合并），
  /// 绝不会跨越两次加载之间的空档把中间日期吞进覆盖范围——这正是旧实现
  /// 用单个 `coveredFrom`/`coveredTo` 跨度产生的假“无消息”结论。
  /// 调用方可多次调用（分页窗口 / targeted lookup），重复调用幂等。
  /// `to.isBefore(from)` 是 no-op。
  void recordCoverage(String roomId,
      {required DateTime from, required DateTime to}) {
    if (to.isBefore(from)) return;
    final room = _room(roomId);
    room.coverage = room.coverage.add(CoverageRange(from, to));
  }

  /// 记录一次 targeted 探测结论（服务端 timestamp_to_event 或本地定位）。
  ///
  /// [anchorTimestamp] 是该 anchor 事件的真实时间戳；只有在它确实早于已记录
  /// 的当天最早事件（或已记录时间未知）时才替换 anchor（保证 anchor 始终指向
  /// 当天最早一条）。**已存在的非空 anchorEventId 绝不会被 null 覆盖**；
  /// [anchorTimestamp] 缺席时也不会写入伪造的 epoch-1 时间戳。
  void recordDayProbe(String roomId, DateTime day,
      {required bool present,
      String? anchorEventId,
      DateTime? anchorTimestamp,
      bool contributeToCoverage = false}) {
    final room = _room(roomId);
    final date = _dateOnly(day);
    final key = dayKey(date);
    if (present) {
      final existing = room.days[key];
      if (existing == null) {
        room.days[key] = _DayEntry(
            anchorEventId: anchorEventId, firstSeenAt: anchorTimestamp);
      } else if (_isEarlier(anchorTimestamp, existing.firstSeenAt)) {
        room.days[key] = _DayEntry(
            anchorEventId: anchorEventId ?? existing.anchorEventId,
            firstSeenAt: anchorTimestamp);
      } else if (existing.anchorEventId == null && anchorEventId != null) {
        // 时间证据不变，但补上缺失的 anchor id。
        room.days[key] = _DayEntry(
            anchorEventId: anchorEventId, firstSeenAt: existing.firstSeenAt);
      }
    } else {
      room.days.remove(key);
      room.emptyDays.add(key);
    }
    if (contributeToCoverage) {
      // 单日探测只贡献这一天：绝不能扩展成整月/整段覆盖。
      recordCoverage(roomId, from: date, to: date);
    }
  }

  /// 单日状态。
  ///
  /// [now] 为 future 判定使用的当前时间：**晚于 `now` 的日期一律 unknown**，
  /// 即使它落在覆盖区间内（区间可能来自设备时间错乱/预加载，不能据此宣称未来
  /// 没有消息）。`now` 为空时不做 future 判定（保持既有行为，避免调用方在
  /// 未提供时钟时行为突变）；需要 future 语义的调用方应显式传入 `now`，
  /// 测试也必须显式传入以保证确定性。
  RoomHistoryDayState dayState(String roomId, DateTime day, {DateTime? now}) {
    final room = _rooms[roomId]?.room;
    if (room == null) return RoomHistoryDayState.unknown;
    return _stateFor(room, _dateOnly(day), now);
  }

  RoomHistoryDayState _stateFor(
      _RoomDayIndex room, DateTime date, DateTime? now) {
    final key = dayKey(date);
    if (room.days.containsKey(key)) return RoomHistoryDayState.knownPresent;
    final createdAt = room.createdAt;
    if (createdAt != null && date.isBefore(createdAt)) {
      return RoomHistoryDayState.knownEmpty;
    }
    if (room.emptyDays.contains(key)) return RoomHistoryDayState.knownEmpty;
    if (!_isFuture(date, now) && room.coverage.containsDay(date)) {
      return RoomHistoryDayState.knownEmpty;
    }
    return RoomHistoryDayState.unknown;
  }

  /// date-only 比较：严格晚于 [now] 所在日历日才是“未来”。
  static bool _isFuture(DateTime date, DateTime? now) {
    if (now == null) return false;
    return date.isAfter(_dateOnly(now));
  }

  String? anchorFor(String roomId, DateTime day) =>
      _rooms[roomId]?.room.days[dayKey(_dateOnly(day))]?.anchorEventId;

  /// 当天 anchor 事件的真实时间戳；未知时为 null（绝不返回哨兵值）。
  @visibleForTesting
  DateTime? anchorTimestampFor(String roomId, DateTime day) =>
      _rooms[roomId]?.room.days[dayKey(_dateOnly(day))]?.firstSeenAt;

  /// 该房间当前的覆盖区间（诊断/测试用；区间之间是真实空档）。
  @visibleForTesting
  CoverageRangeSet coverageRangesFor(String roomId) =>
      _rooms[roomId]?.room.coverage ?? const CoverageRangeSet();

  /// 已知最早的“有消息”日期（用于 earliestMonth，避免 1970 假日期）。
  DateTime? earliestKnownDay(String roomId) {
    final room = _rooms[roomId]?.room;
    if (room == null) return null;
    DateTime? earliest;
    for (final key in room.days.keys) {
      final parsed = DateTime.tryParse(key);
      if (parsed == null) continue;
      if (earliest == null || parsed.isBefore(earliest)) earliest = parsed;
    }
    return earliest;
  }

  /// 房间真实创建时间（若已知）。
  DateTime? roomCreatedAt(String roomId) => _rooms[roomId]?.room.createdAt;

  /// 月级 metadata：只做本地判定，不触发网络/正文/媒体加载。
  ///
  /// [now] 透传给每一天的 future 判定，保证整月使用同一个“现在”。
  RoomHistoryMonthDays monthDays(String roomId, CalendarMonth month,
      {Object? error, DateTime? now}) {
    final room = _rooms[roomId]?.room;
    if (room == null) {
      return RoomHistoryMonthDays(month: month, error: error);
    }
    final states = <int, RoomHistoryDayState>{};
    final anchors = <int, String>{};
    var coverageComplete = true;
    for (var day = 1; day <= month.daysInMonth; day++) {
      final date = DateTime(month.year, month.month, day);
      final state = _stateFor(room, date, now);
      states[day] = state;
      if (state == RoomHistoryDayState.unknown) coverageComplete = false;
      final anchor = room.days[dayKey(date)]?.anchorEventId;
      if (anchor != null) anchors[day] = anchor;
    }
    return RoomHistoryMonthDays(
      month: month,
      dayStates: states,
      anchors: anchors,
      coverageComplete: coverageComplete,
      earliestDay: earliestKnownDay(roomId),
      error: error,
    );
  }

  void clearRoom(String roomId) => _rooms.remove(roomId);

  /// 账号切换/登出：清空全部索引。
  void clear() => _rooms.clear();

  /// 序列化（仅 metadata；供轻量持久化）。
  ///
  /// v2 房间字段：`created`（ms）、`coverageRanges`（`[[startMs, endMs], ...]`）、
  /// `days`（日期键 → anchor event id）、`anchorAt`（日期键 → anchor 真实时间戳 ms，
  /// 缺失即表示时间未知，不再伪造 epoch-1）、`empty`（显式探测为空的日期键）。
  /// 房间按插入顺序输出，便于持久化层裁剪最旧的房间。
  Map<String, Object?> toJson() {
    final ordered = _rooms.entries.toList()
      ..sort((a, b) => a.value.sequence.compareTo(b.value.sequence));
    return {
      'version': schemaVersion,
      'rooms': {
        for (final entry in ordered) entry.key: entry.value.room.toJson(),
      },
    };
  }

  /// 反序列化；版本不匹配时丢弃（宁可重建，不猜测旧格式）。
  static RoomHistoryDayIndex fromJson(Map<String, Object?> json) {
    final index = RoomHistoryDayIndex();
    if (json['version'] != schemaVersion) return index;
    final rooms = json['rooms'];
    if (rooms is! Map) return index;
    for (final entry in rooms.entries) {
      final roomId = entry.key.toString();
      final payload = entry.value;
      if (payload is! Map) continue;
      final room = index._room(roomId);
      final created = payload['created'];
      if (created is int) {
        room.createdAt = DateTime.fromMillisecondsSinceEpoch(created);
      }
      final coverage = payload['coverageRanges'];
      if (coverage != null) {
        room.coverage = CoverageRangeSet.fromJson(coverage);
      }
      final anchorTimes = payload['anchorAt'];
      final days = payload['days'];
      if (days is Map) {
        for (final day in days.entries) {
          final key = day.key.toString();
          final anchor = day.value?.toString() ?? '';
          if (anchor.isEmpty) continue;
          room.days[key] = _DayEntry(
            anchorEventId: anchor,
            firstSeenAt: _timestampFor(anchorTimes, key),
          );
        }
      }
      final empty = payload['empty'];
      if (empty is List) {
        room.emptyDays.addAll(empty.map((value) => value.toString()));
      }
    }
    return index;
  }

  /// 读取 `anchorAt` 中的时间戳；缺失/非整数 → null（时间未知）。
  static DateTime? _timestampFor(Object? anchorTimes, String dayKey) {
    if (anchorTimes is! Map) return null;
    final value = anchorTimes[dayKey];
    if (value is! int) return null;
    return DateTime.fromMillisecondsSinceEpoch(value);
  }
}

/// 房间条目 + 插入顺序（裁剪时保留最近的房间）。
final class _RoomSlot {
  _RoomSlot(this.room, this.sequence);

  final _RoomDayIndex room;
  final int sequence;
}

final class _RoomDayIndex {
  DateTime? createdAt;
  CoverageRangeSet coverage = const CoverageRangeSet();
  final Map<String, _DayEntry> days = {};
  final Set<String> emptyDays = {};

  Map<String, Object?> toJson() => {
        if (createdAt != null) 'created': createdAt!.millisecondsSinceEpoch,
        if (coverage.isNotEmpty) 'coverageRanges': coverage.toJson(),
        'days': {
          for (final day in days.entries)
            day.key: day.value.anchorEventId ?? '',
        },
        if (days.isNotEmpty)
          'anchorAt': {
            for (final day in days.entries)
              if (day.value.firstSeenAt != null)
                day.key: day.value.firstSeenAt!.millisecondsSinceEpoch,
          },
        if (emptyDays.isNotEmpty) 'empty': emptyDays.toList(growable: false),
      };
}

/// 单日 anchor 记录。
///
/// [firstSeenAt] 是 anchor 事件的**真实**时间戳；未知时为 null。
/// 旧实现用 `DateTime.fromMillisecondsSinceEpoch(1)` 兜底，导致重载后哨兵值
/// 参与 `isBefore` 比较，真实事件永远无法替换 anchor；此处以 null 表示“未知”，
/// 且任何比较都把 null 视为“没有更早的证据”。
final class _DayEntry {
  const _DayEntry({this.anchorEventId, this.firstSeenAt});

  final String? anchorEventId;
  final DateTime? firstSeenAt;
}
