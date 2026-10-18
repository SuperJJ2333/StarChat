import 'dart:async';

Future<void> captureThenRepairProjection({
  required Future<void> Function() capture,
  required Future<void> Function() repair,
  required bool Function() isCurrent,
}) async {
  try {
    await capture();
  } catch (_) {
    // Optional persistent capture failure cannot prevent canonical display
    // repair. Repair retains its own identity and revision checks.
  }
  if (isCurrent()) await repair();
}

/// Scheduling may reorder work inside the bounded cache, never its coverage.
List<String> selectProjectionRefreshRooms(List<String> ranked,
    {String? current, Set<String>? changed, int limit = 40}) {
  final selected = [
    if (current != null && ranked.contains(current)) current,
    ...ranked.where((id) => id != current),
  ].take(limit).toList();
  return [
    ...selected.where((id) => id == current || changed?.contains(id) == true),
    ...selected.where((id) => id != current && changed?.contains(id) != true),
  ];
}

/// Coalesces display-only work. Durable invalidation stays on the caller path.
final class OptionalProjectionRefresh {
  OptionalProjectionRefresh(this.refresh,
      {this.delay = const Duration(milliseconds: 200)});
  final Future<void> Function(Set<String>? rooms) refresh;
  final Duration delay;
  Timer? _timer;
  Completer<void>? _pending;
  bool _running = false;
  bool _closed = false;
  bool _full = false;
  final _rooms = <String>{};

  Future<void> request({Set<String>? rooms}) {
    if (_closed) return Future<void>.value();
    if (rooms == null) {
      _full = true;
    } else {
      _rooms.addAll(rooms);
    }
    final pending = _pending ??= Completer<void>();
    _arm();
    return pending.future;
  }

  void _arm() {
    if (_closed || _running || _timer != null || _pending == null) return;
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(_run());
    });
  }

  Future<void> _run() async {
    final completion = _pending;
    if (_closed || completion == null) return;
    _pending = null;
    final rooms = _full ? null : Set<String>.of(_rooms);
    _full = false;
    _rooms.clear();
    _running = true;
    try {
      await refresh(rooms);
      completion.complete();
    } catch (error, stack) {
      completion.completeError(error, stack);
    } finally {
      _running = false;
      _arm();
    }
  }

  void close() {
    _closed = true;
    _timer?.cancel();
    _pending?.complete();
    _pending = null;
    _rooms.clear();
  }
}
