import 'dart:async';

import 'room_timeline_controller.dart';

/// A tile releases its demand on disposal. An explicit tap is a separate
/// consumer and can retain the shared lookup after that tile leaves the grid.
final class SearchMediaDemand {
  bool _active = true;
  bool get isActive => _active;
  final _listeners = <void Function()>{};

  void release() {
    if (!_active) return;
    _active = false;
    final listeners = _listeners.toList();
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }
}

final class _SearchMediaFlight {
  _SearchMediaFlight(this.revision, this.source);
  final int revision;
  final String? source;
  final result = Completer<RoomMessageViewModel?>();
  final consumers = <SearchMediaDemand, void Function()>{};
  bool tapped = false;
  bool started = false;
  bool get hasDemand => tapped || consumers.isNotEmpty;

  void detachConsumers() {
    for (final entry in consumers.entries) {
      entry.key._listeners.remove(entry.value);
    }
    consumers.clear();
  }
}

/// Search results name a source, but only the live SDK may authorize media.
/// Pending work belongs to mounted tiles or explicit taps. Disposing the last
/// tile removes queued work immediately, without waiting on a running SDK read.
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
  final _flights = <String, _SearchMediaFlight>{};
  int generation = 0;
  int _running = 0;
  bool _pumping = false;

  bool allows(String id) => isActive() && isVisible(id);
  void invalidate() {
    generation++;
    final previous = _flights.values.toList();
    _flights.clear();
    for (final flight in previous) {
      flight.detachConsumers();
      // Real admitted work keeps its slot and future until it settles.
      if (!flight.started) flight.result.complete(null);
    }
  }

  Future<RoomMessageViewModel?> resolve(String id,
      {SearchMediaDemand? demand}) {
    if (!allows(id) || (demand != null && !demand.isActive)) {
      return Future.value();
    }
    final flight = _flights.putIfAbsent(
        id, () => _SearchMediaFlight(generation, sourceOf(id)));
    _retain(id, flight, demand);
    _pump();
    return flight.result.future;
  }

  void _retain(
      String id, _SearchMediaFlight flight, SearchMediaDemand? demand) {
    if (demand == null) {
      flight.tapped = true;
      return;
    }
    if (flight.consumers.containsKey(demand)) return;
    void released() {
      flight.consumers.remove(demand);
      if (!flight.started && !flight.hasDemand) {
        _remove(id, flight);
        flight.result.complete(null);
      }
    }

    flight.consumers[demand] = released;
    demand._listeners.add(released);
  }

  bool _valid(String id, _SearchMediaFlight flight) =>
      flight.hasDemand &&
      flight.revision == generation &&
      flight.source != null &&
      sourceOf(id) == flight.source &&
      allows(id);

  void _remove(String id, _SearchMediaFlight flight) {
    flight.detachConsumers();
    if (identical(_flights[id], flight)) _flights.remove(id);
  }

  void _pump() {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_running < 4) {
        MapEntry<String, _SearchMediaFlight>? next;
        for (final entry in _flights.entries) {
          if (!entry.value.started) {
            next = entry;
            break;
          }
        }
        if (next == null) return;
        final id = next.key, flight = next.value;
        if (!_valid(id, flight)) {
          _remove(id, flight);
          flight.result.complete(null);
          continue;
        }
        flight.started = true;
        _running++;
        unawaited(_run(id, flight));
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _run(String id, _SearchMediaFlight flight) async {
    try {
      await hintSource(id, flight.source!);
      if (!_valid(id, flight)) {
        flight.result.complete(null);
        return;
      }
      final message = await lookup(id);
      if (!_valid(id, flight) ||
          message == null ||
          message.id != id ||
          message.isRecalled ||
          message.isFlashPhoto ||
          (message.kind != RoomMessageKind.image &&
              message.kind != RoomMessageKind.video)) {
        flight.result.complete(null);
      } else {
        flight.result.complete(message);
      }
    } catch (error, stack) {
      if (_valid(id, flight)) {
        flight.result.completeError(error, stack);
      } else {
        flight.result.complete(null);
      }
    } finally {
      _remove(id, flight);
      _running--;
      _pump();
    }
  }
}
