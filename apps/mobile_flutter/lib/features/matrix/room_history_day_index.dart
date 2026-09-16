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
/// - 落在“已连续覆盖”区间内且无事件，或早于房间创建时间 → knownEmpty；
/// - 其余 → unknown（需要 targeted lookup 才能定论）。
final class RoomHistoryDayIndex {
  RoomHistoryDayIndex();

  /// schema/version metadata（持久化时必须携带，便于未来迁移）。
  static const schemaVersion = 1;

  final Map<String, _RoomDayIndex> _rooms = {};

  @visibleForTesting
  int get roomCount => _rooms.length;

  static String dayKey(DateTime day) => '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  _RoomDayIndex _room(String roomId) =>
      _rooms.putIfAbsent(roomId, () => _RoomDayIndex());

  /// 记录房间真实创建时间（m.room.create）：早于它的日期可确认无消息。
  void recordRoomCreatedAt(String roomId, DateTime? createdAt) {
    if (createdAt == null) return;
    _room(roomId).createdAt = _dateOnly(createdAt);
  }

  /// 记录本机已解密、用户可见的事件（只留日期 + 当天最早事件作为 anchor）。
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
      } else if (event.timestamp.isBefore(existing.firstSeenAt)) {
        room.days[key] =
            _DayEntry(anchorEventId: event.eventId, firstSeenAt: event.timestamp);
      }
    }
  }

  /// 记录连续覆盖区间（本机连续分页得到的可信范围）。
  void recordCoverage(String roomId,
      {required DateTime from, required DateTime to}) {
    if (to.isBefore(from)) return;
    final room = _room(roomId);
    final lower = _dateOnly(from);
    final upper = _dateOnly(to);
    if (room.coveredFrom == null || lower.isBefore(room.coveredFrom!)) {
      room.coveredFrom = lower;
    }
    if (room.coveredTo == null || upper.isAfter(room.coveredTo!)) {
      room.coveredTo = upper;
    }
  }

  /// 记录一次 targeted 探测结论（服务端 timestamp_to_event 或本地定位）。
  ///
  /// [anchorTimestamp] 是该 anchor 事件的真实时间戳；只有在它确实早于已记录
  /// 的当天最早事件时才替换 anchor（保证 anchor 始终指向当天最早一条）。
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
            anchorEventId: anchorEventId, firstSeenAt: anchorTimestamp ?? date);
      } else if (anchorTimestamp != null &&
          anchorTimestamp.isBefore(existing.firstSeenAt)) {
        room.days[key] = _DayEntry(
            anchorEventId: anchorEventId, firstSeenAt: anchorTimestamp);
      }
    } else {
      room.days.remove(key);
      room.emptyDays.add(key);
    }
    if (contributeToCoverage) {
      recordCoverage(roomId, from: date, to: date);
    }
  }

  /// 单日状态（[now] 用于 future 判定：未来日期一律 unknown，不标空）。
  RoomHistoryDayState dayState(String roomId, DateTime day, {DateTime? now}) {
    final room = _rooms[roomId];
    if (room == null) return RoomHistoryDayState.unknown;
    return _stateFor(room, _dateOnly(day));
  }

  RoomHistoryDayState _stateFor(_RoomDayIndex room, DateTime date) {
    final key = dayKey(date);
    if (room.days.containsKey(key)) return RoomHistoryDayState.knownPresent;
    final createdAt = room.createdAt;
    if (createdAt != null && date.isBefore(createdAt)) {
      return RoomHistoryDayState.knownEmpty;
    }
    if (room.emptyDays.contains(key)) return RoomHistoryDayState.knownEmpty;
    final from = room.coveredFrom;
    final to = room.coveredTo;
    if (from != null && to != null &&
        !date.isBefore(from) && !date.isAfter(to)) {
      return RoomHistoryDayState.knownEmpty;
    }
    return RoomHistoryDayState.unknown;
  }

  String? anchorFor(String roomId, DateTime day) =>
      _rooms[roomId]?.days[dayKey(_dateOnly(day))]?.anchorEventId;

  /// 已知最早的“有消息”日期（用于 earliestMonth，避免 1970 假日期）。
  DateTime? earliestKnownDay(String roomId) {
    final room = _rooms[roomId];
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
  DateTime? roomCreatedAt(String roomId) => _rooms[roomId]?.createdAt;

  /// 月级 metadata：只做本地判定，不触发网络/正文/媒体加载。
  RoomHistoryMonthDays monthDays(String roomId, CalendarMonth month,
      {Object? error}) {
    final room = _rooms[roomId];
    if (room == null) {
      return RoomHistoryMonthDays(month: month, error: error);
    }
    final states = <int, RoomHistoryDayState>{};
    final anchors = <int, String>{};
    var coverageComplete = true;
    for (var day = 1; day <= month.daysInMonth; day++) {
      final date = DateTime(month.year, month.month, day);
      final state = _stateFor(room, date);
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
  Map<String, Object?> toJson() => {
        'version': schemaVersion,
        'rooms': {
          for (final entry in _rooms.entries)
            entry.key: {
              if (entry.value.createdAt != null)
                'created': entry.value.createdAt!.millisecondsSinceEpoch,
              if (entry.value.coveredFrom != null)
                'from': entry.value.coveredFrom!.millisecondsSinceEpoch,
              if (entry.value.coveredTo != null)
                'to': entry.value.coveredTo!.millisecondsSinceEpoch,
              'days': {
                for (final day in entry.value.days.entries)
                  day.key: day.value.anchorEventId ?? '',
              },
              if (entry.value.emptyDays.isNotEmpty)
                'empty': entry.value.emptyDays.toList(growable: false),
            },
        },
      };

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
      final from = payload['from'];
      if (from is int) room.coveredFrom = DateTime.fromMillisecondsSinceEpoch(from);
      final to = payload['to'];
      if (to is int) room.coveredTo = DateTime.fromMillisecondsSinceEpoch(to);
      final days = payload['days'];
      if (days is Map) {
        for (final day in days.entries) {
          final key = day.key.toString();
          final anchor = day.value?.toString() ?? '';
          if (anchor.isEmpty) continue;
          room.days[key] = _DayEntry(anchorEventId: anchor);
        }
      }
      final empty = payload['empty'];
      if (empty is List) {
        room.emptyDays.addAll(empty.map((value) => value.toString()));
      }
    }
    return index;
  }
}

final class _RoomDayIndex {
  DateTime? createdAt;
  DateTime? coveredFrom;
  DateTime? coveredTo;
  final Map<String, _DayEntry> days = {};
  final Set<String> emptyDays = {};
}

final class _DayEntry {
  _DayEntry({this.anchorEventId, DateTime? firstSeenAt})
      : firstSeenAt = firstSeenAt ?? DateTime.fromMillisecondsSinceEpoch(1);

  final String? anchorEventId;
  final DateTime firstSeenAt;
}
