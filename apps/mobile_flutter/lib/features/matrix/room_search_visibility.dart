import 'chat_search_query_controller.dart';

/// Applies the source room's local visibility rules to an already projected
/// database row. The row is authoritative for edits and redactions; a cached
/// live timeline message must never replace its contents.
ChatSearchMessage? visibleLocalSearchRow({
  required String sourceRoomId,
  required ChatSearchMessage row,
  required bool Function(String roomId, String eventId, DateTime timestamp)
      isHidden,
}) {
  if (!row.isDisplayable ||
      row.isFlashPhoto ||
      (row.visibleText.isEmpty && row.mediaCategory == null) ||
      isHidden(sourceRoomId, row.eventId, row.timestamp)) {
    return null;
  }
  return row;
}

/// Tracks only accepted search results so a later tap checks the same source
/// room that produced the result. Search cancellation discards this index.
final class LocalSearchResultVisibility {
  final _sources = <String, ({String roomId, DateTime timestamp})>{};

  void remember(String sourceRoomId, ChatSearchMessage row) {
    _sources[row.eventId] = (roomId: sourceRoomId, timestamp: row.timestamp);
  }

  bool isVisible(
    String eventId, {
    required bool Function(String roomId, String eventId, DateTime timestamp)
        isHidden,
  }) {
    final source = _sources[eventId];
    return source != null &&
        !isHidden(source.roomId, eventId, source.timestamp);
  }

  void clear() => _sources.clear();
}
