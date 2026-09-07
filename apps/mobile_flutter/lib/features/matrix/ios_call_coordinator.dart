import 'dart:async';

final class IosCallSnapshot {
  const IosCallSnapshot(
      {this.callId,
      this.roomId,
      this.phase = 'idle',
      this.incoming = false,
      this.video = false,
      this.muted = false});
  final String? callId;
  final String? roomId;
  final String phase;
  final bool incoming;
  final bool video;
  final bool muted;
  String? get key =>
      callId == null || roomId == null ? null : '$roomId\u0000$callId';
  bool get terminal =>
      const {'ended', 'failed', 'permissionDenied', 'idle'}.contains(phase);
  Map<String, Object?> get arguments => {
        'callId': callId,
        'roomId': roomId,
        'phase': phase,
        'video': video,
        'muted': muted,
        'incoming': incoming
      };
}

/// The native call is a presentation. Only a matching verified Matrix session
/// and an explicit user action may answer. Actions never match by timing alone.
final class IosCallCoordinator {
  IosCallCoordinator(
      {required this.owner,
      required this.snapshot,
      required this.invoke,
      required this.accept,
      required this.end,
      required this.mute,
      required this.sync,
      required this.registerTokens,
      this.cancelPendingAnswer,
      DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final IosCallSnapshot Function() snapshot;
  final String owner;
  final void Function()? cancelPendingAnswer;
  final Future<Object?> Function(String, Object?) invoke;
  final Future<void> Function() accept;
  final Future<void> Function() end;
  final Future<void> Function(bool) mute;
  final Future<void> Function() sync;
  final Future<void> Function(Map<String, Object?>) registerTokens;
  final DateTime Function() _now;
  final _pending = <String, Map<String, Object?>>{};
  final _pendingMute = <String, Map<String, Object?>>{};
  final _answered = <String>{};
  final _ended = <String>{};
  final _cancelRequested = <String>{};
  final _shown = <String>{};
  IosCallSnapshot? _last;
  bool _disposed = false;
  Future<void> _tail = Future.value();

  Future<void> _serial(Future<void> Function() work) {
    final next = _tail.then((_) async {
      if (!_disposed) await work();
    });
    _tail = next.catchError((_) {});
    return next;
  }

  Future<void> start() async {
    final tokens = await invoke('start', null);
    if (_disposed) return;
    if (tokens is Map) {
      unawaited(
          registerTokens(Map<String, Object?>.from(tokens)).catchError((_) {}));
    }
    final result = await invoke('ready', null);
    if (_disposed) return;
    if (result is Map && result['actions'] is List) {
      for (final action in result['actions'] as List) {
        await handle('event', action);
      }
    }
  }

  Future<Object?> handle(String method, Object? raw) async {
    if (_disposed) return false;
    if (raw is! Map || raw['owner'] != owner) return false;
    if (method == 'tokensChanged') {
      await registerTokens(Map<String, Object?>.from(raw));
      return true;
    }
    if (method != 'event') return false;
    final action = Map<String, Object?>.from(raw);
    final id = action['callId'];
    final room = action['roomId'];
    final at = action['at'];
    if (id is! String ||
        id.isEmpty ||
        room is! String ||
        room.isEmpty ||
        at is! int) {
      return false;
    }
    final age = _now().millisecondsSinceEpoch - at;
    if (age > 45000 || age < -5000) return false;
    final key = '$room\u0000$id';
    if (action['action'] == 'end' && snapshot().key == key) {
      if (_cancelRequested.length >= 64) {
        _cancelRequested.remove(_cancelRequested.first);
      }
      _cancelRequested.add(key);
      cancelPendingAnswer?.call();
    }
    if (action['action'] == 'incoming') {
      unawaited(sync().catchError((_) {}));
      return true;
    }
    if (!const {'answer', 'end', 'mute'}.contains(action['action'])) {
      return false;
    }
    await _serial(() async {
      if (_pending.length >= 8 && !_pending.containsKey(key)) {
        _pending.remove(_pending.keys.first);
      }
      // A terminal action dominates late duplicated answers for this same call.
      if (_ended.contains(key)) return;
      if (_pending[key]?['action'] == 'end' && action['action'] != 'end') {
        return;
      }
      if (action['action'] == 'mute') {
        if (_pendingMute.length >= 8 && !_pendingMute.containsKey(key)) {
          _pendingMute.remove(_pendingMute.keys.first);
        }
        _pendingMute[key] = action;
      } else {
        _pending[key] = action;
        if (action['action'] == 'end') _pendingMute.remove(key);
      }
      await _update();
    });
    if (!_disposed) unawaited(sync().catchError((_) {}));
    return true;
  }

  Future<void> update() => _serial(_update);

  Future<void> _update() async {
    final now = _now().millisecondsSinceEpoch;
    _pending.removeWhere((_, action) => now - (action['at'] as int) > 45000);
    _pendingMute
        .removeWhere((_, action) => now - (action['at'] as int) > 45000);
    final current = snapshot();
    final key = current.key;
    if (current.terminal) {
      final previous = _last;
      if (previous?.key != null) {
        _pending.remove(previous!.key);
        _pendingMute.remove(previous.key);
        await invoke('endCall', previous.arguments);
      }
      _last = null;
      return;
    }
    if (key == null) return;
    _last = current;
    if (_shown.length > 64) _shown.remove(_shown.first);
    if (_answered.length > 64) _answered.remove(_answered.first);
    if (_ended.length > 64) _ended.remove(_ended.first);
    if (current.incoming && current.phase == 'ringing' && _shown.add(key)) {
      await invoke(
          'showIncoming', {...current.arguments, 'expiresAt': now + 30000});
    }
    if (_disposed) return;
    await invoke('reportState', current.arguments);
    if (_disposed) return;
    final action = _pending[key];
    switch (action?['action']) {
      case 'answer':
        if (_cancelRequested.contains(key)) {
          _pending.remove(key);
          return;
        }
        if (!current.incoming || current.phase != 'ringing') return;
        _pending.remove(key);
        if (_answered.add(key)) await accept();
      case 'end':
        _pending.remove(key);
        if (_ended.add(key)) await end();
    }
    final muteAction = _pendingMute[key];
    if (!_disposed &&
        !_ended.contains(key) &&
        snapshot().key == key &&
        !snapshot().terminal &&
        muteAction?['muted'] is bool) {
      _pendingMute.remove(key);
      await mute(muteAction!['muted'] as bool);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _pending.clear();
    _pendingMute.clear();
    await _tail;
    await invoke('stop', null);
  }
}
