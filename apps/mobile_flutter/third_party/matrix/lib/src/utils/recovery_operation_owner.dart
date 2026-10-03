import 'dart:async';

/// One immutable resource lifetime. Revocation closes admission synchronously;
/// deadlines never remove actual outstanding writes from the drain set.
final class RecoveryOperationOwner {
  RecoveryOperationOwner({required this.identity, required this.isCurrent});

  final Object identity;
  final bool Function() isCurrent;
  bool _revoked = false;
  final Set<Future<void>> _writes = {};
  bool get active => !_revoked && isCurrent();
  int get pendingWrites => _writes.length;

  void check() {
    if (!active) throw StateError('E2EE_RECOVERY_OWNER_REVOKED');
  }

  void revoke() => _revoked = true;

  Future<T> read<T>(Future<T> Function() action) async {
    check();
    final value = await action();
    check();
    return value;
  }

  Future<T> write<T>(Future<T> Function() action) {
    check();
    final settled = Completer<void>();
    _writes.add(settled.future);
    // Register BEFORE invoking action, including its synchronous prefix.
    return Future<T>.sync(action).whenComplete(() {
      _writes.remove(settled.future);
      settled.complete();
    });
  }

  Future<void> drain() async {
    while (_writes.isNotEmpty) {
      await Future.wait(_writes.toList(growable: false));
    }
  }
}
