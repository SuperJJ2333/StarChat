/// Sort an owned presentation list without changing the SDK's pagination order.
/// Equal timestamps retain their input order; already ordered lists need no
/// allocation. Raw event references can be sorted before projecting a window.
void sortTimelineChronologically<T>(
    List<T> entries, DateTime Function(T) timestampOf) {
  var ordered = true;
  if (entries.length < 2) return;
  var previous = timestampOf(entries.first);
  for (var i = 1; i < entries.length; i++) {
    final current = timestampOf(entries[i]);
    if (previous.isAfter(current)) {
      ordered = false;
      break;
    }
    previous = current;
  }
  if (ordered) return;
  final indexed = [
    for (var i = 0; i < entries.length; i++)
      (entry: entries[i], time: timestampOf(entries[i]), index: i),
  ]..sort((a, b) {
      final time = a.time.compareTo(b.time);
      return time != 0 ? time : a.index.compareTo(b.index);
    });
  for (var i = 0; i < entries.length; i++) {
    entries[i] = indexed[i].entry;
  }
}

/// Pending work is retained by its owner even when outside the visible window.
/// Open ends admit work older/newer than the loaded source only at that edge.
bool timelineWindowContains(DateTime timestamp,
    {required DateTime? first,
    required DateTime? last,
    required bool hasEarlier,
    required bool hasLater}) {
  if (first == null || last == null) return !hasEarlier && !hasLater;
  return !(hasEarlier && timestamp.isBefore(first)) &&
      !(hasLater && timestamp.isAfter(last));
}
