/// Bounded event identities for device-local index maintenance. Never bodies.
final class RoomSearchEventDelta {
  RoomSearchEventDelta({this.capacity = 2048});
  final int capacity;
  final _ids = <String>{};
  bool _rescan = false;
  void add(Map<String, dynamic> event) {
    final content = event['content'];
    for (final value in [
      event['event_id'],
      event['redacts'],
      if (content is Map) content['redacts']
    ]) {
      if (value is! String || value.isEmpty) continue;
      if (_ids.length >= capacity && !_ids.contains(value)) {
        _ids.clear();
        _rescan = true;
      }
      _ids.add(value);
    }
  }

  ({List<String> ids, bool rescan}) drain() {
    final result = (ids: _ids.toList(growable: false), rescan: _rescan);
    _ids.clear();
    _rescan = false;
    return result;
  }
}
