/// Optional, bounded reads of already persisted sessions. Never creates keys.
final class SendingSessionWarmup {
  SendingSessionWarmup(
      {required this.candidates,
      required this.load,
      required this.isActive,
      this.limit = 8});
  final List<String> Function() candidates;
  final Future<void> Function(String) load;
  final bool Function() isActive;
  final int limit;
  final _attempted = <String>{};
  String? _current;
  Future<void>? _flight;

  Future<void> schedule({String? current}) {
    if (current != null) _current = current;
    return _flight ??= _run().whenComplete(() => _flight = null);
  }

  Future<void> _run() async {
    while (isActive() && _attempted.length < limit) {
      final available = candidates();
      final ordered = [
        if (_current != null && available.contains(_current)) _current!,
        ...available.where((id) => id != _current),
      ];
      final pending = ordered.where((id) => !_attempted.contains(id));
      if (pending.isEmpty) return;
      final next = pending.first;
      _attempted.add(next);
      if (!isActive()) return;
      try {
        await load(next);
      } catch (_) {
        // A normal send can retry independently of this optional read.
      }
    }
  }
}
