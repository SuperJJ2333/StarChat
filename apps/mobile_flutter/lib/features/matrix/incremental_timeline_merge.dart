/// Merges immutable projection objects while allowing mutable source lists.
/// Comparing IDs/identities is linear; only new/replaced rows need sorting.
final class IncrementalTimelineMerge<T> {
  IncrementalTimelineMerge({required this.idOf, required this.compare});
  final String Function(T) idOf;
  final int Function(T, T) compare;
  Map<String, T> _byId = {};
  List<T> _sorted = [];

  void clear() {
    _byId = {};
    _sorted = [];
  }

  List<T> update(Iterable<T> rows) {
    final next = <String, T>{};
    final changed = <T>[];
    for (final row in rows) {
      final id = idOf(row);
      if (next.containsKey(id)) continue;
      next[id] = row;
      if (!identical(_byId[id], row)) changed.add(row);
    }
    if (changed.isEmpty && next.length == _byId.length) return _sorted;
    changed.sort(compare);
    final result = <T>[];
    var index = 0;
    for (final old in _sorted) {
      if (!identical(next[idOf(old)], old)) continue;
      while (index < changed.length && compare(changed[index], old) < 0) {
        result.add(changed[index++]);
      }
      result.add(old);
    }
    result.addAll(changed.skip(index));
    _byId = next;
    return _sorted = List.unmodifiable(result);
  }
}
