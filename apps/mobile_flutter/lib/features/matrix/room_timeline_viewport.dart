import 'room_timeline_controller.dart';

/// The source holds authoritative SDK references, not a second message store.
/// Only [snapshot] retains presentation models; explicit queries are transient.
final class RoomTimelineViewport<T> {
  RoomTimelineViewport(
      {required this.idOf,
      required this.project,
      this.initialCount = 40,
      this.maximumCount = 200})
      : _count = initialCount;
  final String Function(T) idOf;
  final RoomMessageViewModel Function(T) project;
  final int initialCount;
  final int maximumCount;
  List<T> _source = const [];
  final _indices = <String, int>{};
  List<RoomMessageViewModel> _models = const [];
  int _start = 0;
  int _count;
  bool _latest = true;
  String? _startId;
  int get total => _source.length;
  bool get hasEarlier => _start > 0;
  bool get hasLater => _start + _count < total;
  int get retainedModels => _models.length;

  void update(List<T> source) {
    var firstChanged = 0;
    var sourceChanged = source.length != _source.length;
    final common =
        source.length < _source.length ? source.length : _source.length;
    while (firstChanged < common) {
      if (!identical(source[firstChanged], _source[firstChanged])) {
        sourceChanged = true;
        if (idOf(source[firstChanged]) != idOf(_source[firstChanged])) break;
      }
      firstChanged++;
    }
    // Content replacement preserves its O(1) index. Structural changes update
    // only the changed suffix; append never clears the entire history index.
    if (firstChanged < _source.length || source.length != _source.length) {
      for (var i = firstChanged; i < _source.length; i++) {
        _indices.remove(idOf(_source[i]));
      }
      for (var i = firstChanged; i < source.length; i++) {
        _indices[idOf(source[i])] = i;
      }
    }
    if (sourceChanged) _source = List.unmodifiable(source);
    if (_latest) {
      _start = (total - _count).clamp(0, total);
    } else {
      _start = _indices[_startId] ??
          _start.clamp(0, (total - _count).clamp(0, total));
    }
    _remember();
  }

  void _remember() {
    _startId = _start < total ? idOf(_source[_start]) : null;
  }

  void pin() {
    _latest = false;
    _remember();
  }

  void latest() {
    _latest = true;
    _start = (total - _count).clamp(0, total);
    _remember();
  }

  bool anchor(String id) {
    final index = _indices[id];
    if (index == null) return false;
    _latest = false;
    _count = maximumCount;
    _start = (index - maximumCount ~/ 2)
        .clamp(0, (total - maximumCount).clamp(0, total));
    _remember();
    return true;
  }

  void earlier() {
    final end = (_start + _count).clamp(0, total);
    _count = maximumCount;
    _start = (_start - maximumCount ~/ 2).clamp(0, total);
    if (end - _start < maximumCount) {
      _start = (end - maximumCount).clamp(0, total);
    }
    _latest = false;
    _remember();
  }

  void later() {
    _count = maximumCount;
    _start =
        (_start + maximumCount ~/ 2).clamp(0, (total - _count).clamp(0, total));
    _latest = _start + _count >= total;
    _remember();
  }

  RoomMessageViewModel? find(String id) {
    final index = _indices[id];
    return index == null ? null : project(_source[index]);
  }

  DateTime? previousTimestamp(String id) {
    final index = _indices[id];
    return index == null || index == 0
        ? null
        : project(_source[index - 1]).timestamp;
  }

  RoomMessageViewModel? get newest =>
      _source.isEmpty ? null : project(_source.last);
  Iterable<RoomMessageViewModel> get all sync* {
    for (final entry in _source) {
      yield project(entry);
    }
  }

  List<RoomMessageViewModel> snapshot() {
    final next = <RoomMessageViewModel>[];
    final old = {for (final message in _models) message.id: message};
    for (var i = _start; i < (_start + _count).clamp(0, total); i++) {
      final model = project(_source[i]);
      final before = old[model.id];
      next.add(
          before != null && before.samePresentation(model) ? before : model);
    }
    if (next.length == _models.length) {
      var same = true;
      for (var i = 0; i < next.length; i++) {
        if (!identical(next[i], _models[i])) {
          same = false;
          break;
        }
      }
      if (same) return _models;
    }
    return _models = List.unmodifiable(next);
  }
}
