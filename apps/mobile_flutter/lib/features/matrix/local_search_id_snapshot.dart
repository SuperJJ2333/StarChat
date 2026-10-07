import 'dart:collection';

/// A bounded raw page can contain fewer visible rows, including none. Its
/// continuation describes storage work rather than the number of projections.
final class LocalHistoryPage<T> extends ListBase<T> {
  LocalHistoryPage(
    Iterable<T> rows, {
    required this.nextOffset,
    required this.hasMore,
    required this.rawCount,
  }) : _rows = List.unmodifiable(rows);
  final List<T> _rows;
  final int nextOffset, rawCount;
  final bool hasMore;
  @override
  int get length => _rows.length;
  @override
  set length(int value) => throw UnsupportedError('Immutable history page');
  @override
  T operator [](int index) => _rows[index];
  @override
  void operator []=(int index, T value) =>
      throw UnsupportedError('Immutable history page');
}

/// One room query's ordered local event IDs. The Matrix database adapter may
/// keep the IDs in memory or use bounded page anchors for very large rooms.
abstract interface class LocalSearchIdSnapshot {
  Future<List<String>> page(int offset, int limit);
  void dispose();
}

abstract interface class LocalSearchIdSnapshotCheckpoint {
  Future<LocalSearchIdSnapshot> checkpoint();
}
