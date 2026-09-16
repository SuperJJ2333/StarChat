import 'package:flutter/foundation.dart';

import 'room_history_day_index.dart';

export 'room_history_day_index.dart'
    show CalendarMonth, RoomHistoryDayState, RoomHistoryMonthDays;

/// Raw local timestamp metadata for calendar markers. It intentionally carries
/// no message body, member, media, or presentation projection.
@immutable
final class RoomHistoryDayMetadata {
  const RoomHistoryDayMetadata(this.day);
  final DateTime day;
}

@immutable
final class RoomHistoryDayLocation {
  const RoomHistoryDayLocation({required this.eventId, required this.day});
  final String eventId;
  final DateTime day;
}

/// The remote context still has pages after the bounded date scan. This is
/// deliberately distinct from a confirmed day without a displayable message.
final class RoomHistoryLookupIncomplete implements Exception {
  const RoomHistoryLookupIncomplete();
}

/// A newer date selection, return-to-live action, or lease cancellation won.
final class RoomHistoryLookupCancelled implements Exception {
  const RoomHistoryLookupCancelled();
}

/// Optional bounded date lookup. Legacy timeline adapters remain valid.
abstract interface class RoomHistoryDateCapability {
  Iterable<RoomHistoryDayMetadata> get loadedDayMetadata;
  bool get isViewingHistoryContext;
  Future<RoomHistoryDayLocation?> locateDay(DateTime localDay);
  void cancelPendingDateLookup();
  void selectLatest();

  /// 日期索引中已知的最早月份（可为 null = 仍可向前探索，但不得伪造 1970）。
  CalendarMonth? get earliestMonth;

  /// 月级 metadata 查询（Task A）。
  ///
  /// 只读日期 metadata / 覆盖状态：不加载该月聊天正文、不下载媒体；
  /// 本地索引优先，缺覆盖时做**有界**探测（最多 2 次 timestamp_to_event）。
  /// generation safe / cancellation safe：过期结果必须被丢弃。
  Future<RoomHistoryMonthDays> loadMonthDays(CalendarMonth month);

  /// 取消在途月查询（切月/退出）。
  void cancelMonthLookup();

  /// 本地索引里“该日最早可见事件”的 anchor（无则 null）。
  ///
  /// 用于跳过重复的 timestamp_to_event：月 metadata 已经给出 anchor 时，
  /// 定位该日无需再次访问服务端。
  String? anchorForDay(DateTime localDay);
}
