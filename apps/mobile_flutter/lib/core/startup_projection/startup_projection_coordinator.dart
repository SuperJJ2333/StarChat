import 'dart:async';

/// A permit is tied to one owner and one exact, quiescent snapshot revision.
final class StartupProjectionCapture {
  StartupProjectionCapture._(this.owner, this.revision);
  final Object owner;
  final int revision;
}

/// In-memory display only: deliberately not accepted by commit().
final class StartupProjectionDisplayCapture {
  StartupProjectionDisplayCapture._(this.owner, this.revision);
  final Object owner;
  final int revision;
}

final class StartupProjectionMutation {
  StartupProjectionMutation._(this._owner, this.id, this.beforeApply);
  final StartupProjectionCoordinator _owner;
  final int id;
  final Future<void> beforeApply;
  bool _finished = false;
  void finish({required bool applied}) {
    if (_finished) return;
    _finished = true;
    _owner._finish(id, applied);
  }
}

/// The secure serializer supplied by the store is used only for head writes.
/// Never hold it during capture, encryption, network, or SDK transactions.
final class StartupProjectionCoordinator {
  StartupProjectionCoordinator({required this.invalidateHead});
  final Future<void> Function() invalidateHead;
  final Object _owner = Object();
  final Set<int> _active = {};
  int _revision = 0;
  int _nextTicket = 0;
  bool _verified = false;
  bool _retired = false;
  bool _poisoned = false;
  bool _displayRevoked = false;
  bool get displayRevoked => _displayRevoked || _retired;
  Future<void> _headWork = Future<void>.value();

  void markVerified() {
    if (_retired || _poisoned) return;
    _verified = true;
  }

  void retire() {
    _retired = true;
    _verified = false;
    _revision++;
  }

  bool get canCapture =>
      _verified && !_retired && !_poisoned && _active.isEmpty;
  StartupProjectionDisplayCapture? beginDisplayCapture() =>
      !_retired && !_poisoned && _active.isEmpty
          ? StartupProjectionDisplayCapture._(_owner, _revision)
          : null;
  bool isDisplayCurrent(StartupProjectionDisplayCapture permit) =>
      !_retired &&
      !_poisoned &&
      _active.isEmpty &&
      identical(permit.owner, _owner) &&
      permit.revision == _revision;
  StartupProjectionCapture? beginCapture() =>
      canCapture ? StartupProjectionCapture._(_owner, _revision) : null;
  bool isCurrent(StartupProjectionCapture permit) =>
      canCapture &&
      identical(permit.owner, _owner) &&
      permit.revision == _revision;

  Future<void> _serializeHead(Future<void> Function() work) {
    final next = _headWork.then((_) => work());
    _headWork = next.catchError((Object _) {});
    return next;
  }

  StartupProjectionMutation beginMutation(String reason) {
    if (_retired) throw StateError('Retired projection owner');
    final id = ++_nextTicket;
    _displayRevoked = true;
    _revision++;
    _active.add(id);
    final before = _serializeHead(invalidateHead).catchError((Object error) {
      _poisoned = true;
      throw error;
    });
    return StartupProjectionMutation._(this, id, before);
  }

  void _finish(int id, bool applied) {
    if (!_active.remove(id)) return;
    _revision++;
    if (!applied) _poisoned = true;
  }

  Future<T> runMutation<T>(String reason, Future<T> Function() apply) async {
    final ticket = beginMutation(reason);
    var applied = false;
    try {
      await ticket.beforeApply;
      if (_retired) throw StateError('Retired projection owner');
      final result = await apply();
      applied = true;
      return result;
    } finally {
      ticket.finish(applied: applied);
    }
  }

  Future<bool> commit(
          StartupProjectionCapture permit, Future<void> Function() writeHead) =>
      _serializeHead(() async {
        if (!isCurrent(permit)) return;
        await writeHead();
        if (!isCurrent(permit)) await invalidateHead();
      }).then((_) => isCurrent(permit));
}
