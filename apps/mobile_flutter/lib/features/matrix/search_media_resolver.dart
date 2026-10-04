import 'dart:async';

import 'room_timeline_controller.dart';

/// Search results name a source, but only the live SDK may authorize media.
/// Keep metadata lookups bounded and share a tap with its visible grid request.
final class SearchMediaResolver {
  SearchMediaResolver(
      {required this.sourceOf,
      required this.isVisible,
      required this.isActive,
      required this.hintSource,
      required this.lookup});
  final String? Function(String) sourceOf;
  final bool Function(String) isVisible;
  final bool Function() isActive;
  final Future<void> Function(String, String) hintSource;
  final Future<RoomMessageViewModel?> Function(String) lookup;
  final _flights = <String, Future<RoomMessageViewModel?>>{};
  int generation = 0;
  int _running = 0;
  Completer<void> _available = Completer<void>();

  bool allows(String id) => isActive() && isVisible(id);
  void invalidate() {
    generation++;
    _flights.clear();
    final available = _available;
    _available = Completer<void>();
    available.complete();
  }

  Future<RoomMessageViewModel?> resolve(String id) {
    if (!allows(id)) return Future.value();
    return _flights.putIfAbsent(id, () {
      late Future<RoomMessageViewModel?> pending;
      pending = _resolve(id, generation, sourceOf(id)).whenComplete(() {
        if (identical(_flights[id], pending)) _flights.remove(id);
      });
      return pending;
    });
  }

  Future<RoomMessageViewModel?> _resolve(
      String id, int revision, String? source) async {
    bool valid() =>
        generation == revision &&
        source != null &&
        sourceOf(id) == source &&
        allows(id);
    while (_running >= 4) {
      await _available.future;
      if (!valid()) return null;
    }
    if (!valid()) return null;
    _running++;
    try {
      await hintSource(id, source!);
      if (!valid()) return null;
      final message = await lookup(id);
      if (!valid() ||
          message == null ||
          message.id != id ||
          message.isRecalled ||
          message.isFlashPhoto ||
          (message.kind != RoomMessageKind.image &&
              message.kind != RoomMessageKind.video)) {
        return null;
      }
      return message;
    } finally {
      _running--;
      final available = _available;
      _available = Completer<void>();
      available.complete();
    }
  }
}
