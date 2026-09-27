import 'bounded_history_search.dart';
import 'chat_search_query_controller.dart';
import 'room_history_day_index.dart';

/// Preserve raw fragment positions when the SDK omits missing event rows.
/// Missing local records are not displayable and cannot establish text coverage.
List<ChatSearchMessage> completeLocalHistoryPage(
    List<String> eventIds, Iterable<ChatSearchMessage> messages) {
  final byId = {for (final row in messages) row.eventId: row};
  return [
    for (final id in eventIds)
      byId[id] ??
          ChatSearchMessage(
              eventId: id,
              senderId: '',
              senderDisplayName: '',
              timestamp: DateTime.fromMillisecondsSinceEpoch(0),
              timelineOrder: 0,
              visibleText: '',
              isDisplayable: false,
              isUndecrypted: true)
  ];
}

/// Rebuildable, lease/account-scoped plaintext projection cache. Nothing is
/// persisted or uploaded. Eviction affects reuse, never local coverage.
final class LocalRoomHistorySnapshot {
  LocalRoomHistorySnapshot({
    required this.roomIds,
    required this.readPage,
    this.sourceRevision,
    this.pageSize = 512,
    this.maxCachedRows = 200000,
    this.maxCachedBytes = 64 * 1024 * 1024,
  });
  final List<String> Function() roomIds;
  final Future<List<ChatSearchMessage>> Function(String, int, int) readPage;
  final int Function()? sourceRevision;
  final int pageSize, maxCachedRows, maxCachedBytes;
  int _generation = 0, _rows = 0, _bytes = 0;
  int? _revision;
  List<String> _rooms = const [];
  final _pages = <(String, int), List<ChatSearchMessage>>{};
  final _pending = <(String, int), Future<List<ChatSearchMessage>>>{};
  Map<String, ChatSearchMessage>? _dates;
  Map<String, String> _dateSources = {};
  Future<void>? _dateLoad;

  int get generation {
    synchronize();
    return _generation;
  }

  List<String> get rooms {
    synchronize();
    return List.unmodifiable(_rooms);
  }

  void clear() {
    _generation++;
    _pages.clear();
    _pending.clear();
    _dates = null;
    _dateSources = {};
    _dateLoad = null;
    _rows = _bytes = 0;
  }

  void synchronize() {
    final ids = roomIds().toSet().toList()..sort();
    final revision = sourceRevision?.call();
    if (revision == _revision && _same(ids, _rooms)) return;
    clear();
    _revision = revision;
    _rooms = ids;
  }

  bool _same(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _check(int generation) {
    synchronize();
    if (generation != _generation) throw const HistorySearchCancelled();
  }

  Future<List<ChatSearchMessage>> page(
      String roomId, int offset, int limit) async {
    synchronize();
    final generation = _generation;
    if (!_rooms.contains(roomId)) throw const HistorySearchCancelled();
    // The configured fixed page size is also the cache key's paging contract.
    if (limit != pageSize) return readPage(roomId, offset, limit);
    final key = (roomId, offset);
    final cached = _pages.remove(key);
    if (cached != null) {
      _pages[key] = cached;
      return cached;
    }
    final pending = _pending[key];
    if (pending != null) return pending;
    final operation = _read(key, generation);
    _pending[key] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_pending[key], operation)) _pending.remove(key);
    }
  }

  int _size(List<ChatSearchMessage> rows) => rows.fold(
      0,
      (n, r) =>
          n +
          256 +
          2 *
              (r.visibleText.length +
                  r.eventId.length +
                  r.senderId.length +
                  r.senderDisplayName.length));
  Future<List<ChatSearchMessage>> _read(
      (String, int) key, int generation) async {
    final rows = List<ChatSearchMessage>.unmodifiable(
        await readPage(key.$1, key.$2, pageSize));
    _check(generation);
    final size = _size(rows);
    if (rows.length <= maxCachedRows && size <= maxCachedBytes) {
      _pages[key] = rows;
      _rows += rows.length;
      _bytes += size;
      while (_rows > maxCachedRows || _bytes > maxCachedBytes) {
        final removed = _pages.remove(_pages.keys.first)!;
        _rows -= removed.length;
        _bytes -= _size(removed);
      }
    }
    return rows;
  }

  /// All states refer to this device's current displayable local records.
  /// A complete local scan is required before publishing any knownEmpty day.
  Future<RoomHistoryMonthDays> monthDays(
    CalendarMonth month, {
    bool Function(String roomId, ChatSearchMessage row)? isVisible,
  }) async {
    synchronize();
    final generation = _generation;
    if (_dates == null) {
      final load = _dateLoad ??= _buildDates(generation, isVisible);
      try {
        await load;
      } finally {
        if (identical(_dateLoad, load)) _dateLoad = null;
      }
    }
    _check(generation);
    final dates = _dates!;
    final states = <int, RoomHistoryDayState>{};
    final anchors = <int, String>{};
    DateTime? earliest;
    for (final row in dates.values) {
      if (earliest == null || row.timestamp.isBefore(earliest)) {
        earliest = row.timestamp;
      }
    }
    for (var d = 1; d <= month.daysInMonth; d++) {
      final row = dates[
          RoomHistoryDayIndex.dayKey(DateTime(month.year, month.month, d))];
      states[d] = row == null
          ? RoomHistoryDayState.knownEmpty
          : RoomHistoryDayState.knownPresent;
      if (row != null) anchors[d] = row.eventId;
    }
    return RoomHistoryMonthDays(
        month: month,
        dayStates: states,
        anchors: anchors,
        coverageComplete: true,
        earliestDay: earliest);
  }

  String? anchorForDay(DateTime day) {
    synchronize();
    return _dates?[RoomHistoryDayIndex.dayKey(day)]?.eventId;
  }

  String? anchorSourceForDay(DateTime day) {
    synchronize();
    return _dateSources[RoomHistoryDayIndex.dayKey(day)];
  }

  Future<void> _buildDates(int generation,
      bool Function(String, ChatSearchMessage)? isVisible) async {
    final dates = <String, ChatSearchMessage>{};
    final sources = <String, String>{};
    for (final room in List<String>.of(_rooms)) {
      var offset = 0;
      while (true) {
        _check(generation);
        final rows = await page(room, offset, pageSize);
        _check(generation);
        for (var i = 0; i < rows.length; i++) {
          final row = rows[i];
          if (row.isDisplayable && (isVisible?.call(room, row) ?? true)) {
            final date = row.timestamp.toLocal();
            final key = RoomHistoryDayIndex.dayKey(date);
            final old = dates[key];
            if (old == null || row.timestamp.isBefore(old.timestamp)) {
              dates[key] = row;
              sources[key] = room;
            }
          }
          if ((i + 1) % 64 == 0) {
            await Future<void>.delayed(Duration.zero);
            _check(generation);
          }
        }
        offset += rows.length;
        if (rows.length < pageSize) break;
      }
    }
    _check(generation);
    _dates = dates;
    _dateSources = sources;
  }
}
