import 'bounded_history_search.dart';
import 'chat_search_query_controller.dart';
import 'room_history_day_index.dart';
import 'local_search_id_snapshot.dart';

/// Preserve raw fragment positions when the SDK omits missing event rows.
/// Missing local records are not displayable and cannot establish text coverage.
List<ChatSearchMessage> completeLocalHistoryPage(
    List<String> eventIds, Iterable<ChatSearchMessage> messages) {
  final byId = {for (final row in messages) row.eventId: row};
  final rows = [
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
  return eventIds is LocalHistoryPage<String>
      ? LocalHistoryPage(rows,
          nextOffset: eventIds.nextOffset,
          hasMore: eventIds.hasMore,
          rawCount: eventIds.rawCount)
      : rows;
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
  int _generation = 0, _mutableGeneration = 0, _rows = 0, _bytes = 0;
  int? _revision;
  List<String> _rooms = const [];
  final _pages = <Object, List<ChatSearchMessage>>{};
  final _pending = <Object, Future<List<ChatSearchMessage>>>{};
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
    _mutableGeneration++;
    _pages.clear();
    _pending.clear();
    _dates = null;
    _dateSources = {};
    _dateLoad = null;
    _rows = _bytes = 0;
  }

  /// A new head changes offset pages and calendar coverage, but ID-keyed
  /// search pages remain valid for a query's frozen event list.
  void invalidateMutablePages() {
    _mutableGeneration++;
    for (final key in _pages.keys.whereType<(String, int)>().toList()) {
      final removed = _pages.remove(key)!;
      _rows -= removed.length;
      _bytes -= _weight(key, removed);
    }
    _pending.removeWhere((key, _) => key is (String, int));
    _dates = null;
    _dateSources = {};
    _dateLoad = null;
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
    final mutableGeneration = _mutableGeneration;
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
    final operation = _read(key, generation, mutableGeneration);
    _pending[key] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_pending[key], operation)) _pending.remove(key);
    }
  }

  Future<List<ChatSearchMessage>> pageByIds(
      String roomId,
      List<String> eventIds,
      Future<List<ChatSearchMessage>> Function(String, List<String>)
          readByIds) async {
    synchronize();
    final generation = _generation;
    if (!_rooms.contains(roomId)) throw const HistorySearchCancelled();
    if (eventIds.isEmpty) return const [];
    final key = _IdPageKey(roomId, eventIds);
    final cached = _pages.remove(key);
    if (cached != null) {
      _pages[key] = cached;
      return cached;
    }
    final pending = _pending[key];
    if (pending != null) return pending;
    final operation = _readIds(key, generation, readByIds);
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
  int _weight(Object key, List<ChatSearchMessage> rows) =>
      128 + _size(rows) + (key is _IdPageKey ? key.bytes : 0);

  void _cache(Object key, List<ChatSearchMessage> rows) {
    final weight = _weight(key, rows);
    if (rows.length > maxCachedRows || weight > maxCachedBytes) return;
    _pages[key] = rows;
    _rows += rows.length;
    _bytes += weight;
    while (_rows > maxCachedRows || _bytes > maxCachedBytes) {
      final oldest = _pages.keys.first;
      final removed = _pages.remove(oldest)!;
      _rows -= removed.length;
      _bytes -= _weight(oldest, removed);
    }
  }

  Future<List<ChatSearchMessage>> _read(
      (String, int) key, int generation, int mutableGeneration) async {
    final page = await readPage(key.$1, key.$2, pageSize);
    final rows = page is LocalHistoryPage<ChatSearchMessage>
        ? page
        : List<ChatSearchMessage>.unmodifiable(page);
    _check(generation);
    if (mutableGeneration != _mutableGeneration) {
      throw const HistorySearchCancelled();
    }
    _cache(key, rows);
    return rows;
  }

  Future<List<ChatSearchMessage>> _readIds(
      _IdPageKey key,
      int generation,
      Future<List<ChatSearchMessage>> Function(String, List<String>)
          readByIds) async {
    final rows = List<ChatSearchMessage>.unmodifiable(completeLocalHistoryPage(
        key.eventIds, await readByIds(key.roomId, key.eventIds)));
    _check(generation);
    _cache(key, rows);
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
    final mutableGeneration = _mutableGeneration;
    if (_dates == null) {
      final load =
          _dateLoad ??= _buildDates(generation, mutableGeneration, isVisible);
      try {
        await load;
      } finally {
        if (identical(_dateLoad, load)) _dateLoad = null;
      }
    }
    _check(generation);
    if (mutableGeneration != _mutableGeneration) {
      throw const HistorySearchCancelled();
    }
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

  Future<void> _buildDates(int generation, int mutableGeneration,
      bool Function(String, ChatSearchMessage)? isVisible) async {
    final dates = <String, ChatSearchMessage>{};
    final sources = <String, String>{};
    for (final room in List<String>.of(_rooms)) {
      var offset = 0;
      while (true) {
        _check(generation);
        if (mutableGeneration != _mutableGeneration) {
          throw const HistorySearchCancelled();
        }
        final rows = await page(room, offset, pageSize);
        _check(generation);
        if (mutableGeneration != _mutableGeneration) {
          throw const HistorySearchCancelled();
        }
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
        if (rows is LocalHistoryPage<ChatSearchMessage>) {
          if (!rows.hasMore) break;
          if (rows.nextOffset <= offset) {
            throw StateError('History cursor did not advance');
          }
          offset = rows.nextOffset;
          await Future<void>.delayed(Duration.zero);
        } else {
          offset += rows.length;
          if (rows.length < pageSize) break;
        }
      }
    }
    _check(generation);
    if (mutableGeneration != _mutableGeneration) {
      throw const HistorySearchCancelled();
    }
    _dates = dates;
    _dateSources = sources;
  }
}

final class _IdPageKey {
  _IdPageKey(this.roomId, List<String> ids)
      : eventIds = List<String>.unmodifiable(ids),
        bytes = ids.fold<int>(0, (n, id) => n + 8 + id.length * 2),
        _hash = Object.hash(roomId, Object.hashAll(ids));
  final String roomId;
  final List<String> eventIds;
  final int bytes;
  final int _hash;

  @override
  int get hashCode => _hash;

  @override
  bool operator ==(Object other) {
    if (other is! _IdPageKey ||
        roomId != other.roomId ||
        eventIds.length != other.eventIds.length) {
      return false;
    }
    for (var i = 0; i < eventIds.length; i++) {
      if (eventIds[i] != other.eventIds[i]) {
        return false;
      }
    }
    return true;
  }
}
