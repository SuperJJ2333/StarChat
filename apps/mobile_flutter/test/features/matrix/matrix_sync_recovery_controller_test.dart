import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_sync_recovery_controller.dart';

void main() {
  test('equivalent transport snapshots do not restart an already healthy loop',
      () async {
    final transport = _FakeTransport({MatrixTransport.wifi});
    final candidates = <bool>[];
    final controller = MatrixSyncRecoveryController(
      transport: transport,
      onCandidate: (force) async => candidates.add(force),
      onOffline: () {},
    );

    controller.start();
    await _settle();
    transport.emit({MatrixTransport.wifi});
    await _settle();

    expect(candidates, [false]);
    controller.dispose();
  });

  test('resume dispatches one forced recovery for an unchanged transport',
      () async {
    final transport = _FakeTransport({MatrixTransport.wifi});
    final candidates = <bool>[];
    final controller = MatrixSyncRecoveryController(
      transport: transport,
      onCandidate: (force) async => candidates.add(force),
      onOffline: () {},
    );

    controller.start();
    await _settle();
    controller.onAppResumed();
    await _settle();

    expect(candidates, [false, true]);
    controller.dispose();
  });

  test('a forced candidate immediately supersedes a hanging soft candidate',
      () async {
    final transport = _FakeTransport({MatrixTransport.wifi});
    final softGate = Completer<void>();
    final forceGate = Completer<void>();
    final candidates = <bool>[];
    final controller = MatrixSyncRecoveryController(
      transport: transport,
      onCandidate: (force) async {
        candidates.add(force);
        await (force ? forceGate : softGate).future;
      },
      onOffline: () {},
    );

    controller.start();
    await _settle();
    controller.onAppResumed();
    await _settle();

    expect(candidates, [false, true],
        reason: 'network recovery cannot wait for a 45-second soft kick');
    controller.onAppResumed();
    await _settle();
    expect(candidates, [false, true],
        reason: 'concurrent force signals must coalesce into one pending run');
    forceGate.complete();
    await _settle();
    expect(candidates, [false, true, true],
        reason: 'the latest force signal must run after the active force');
    softGate.complete();
    await _settle();
    controller.dispose();
  });

  test('transport recovery forces restart and retains a later transport change',
      () async {
    final transport = _FakeTransport({MatrixTransport.wifi});
    final softGate = Completer<void>();
    final forceGate = Completer<void>();
    final candidates = <bool>[];
    final controller = MatrixSyncRecoveryController(
      transport: transport,
      onCandidate: (force) async {
        candidates.add(force);
        await (force ? forceGate : softGate).future;
      },
      onOffline: () {},
    );

    controller.start();
    await _settle();
    transport.emit({});
    await _settle();
    transport.emit({MatrixTransport.wifi});
    await _settle();

    expect(candidates, [false, true],
        reason: 'offline-to-online recovery must not wait for a soft kick');
    transport.emit({MatrixTransport.mobile});
    await _settle();
    expect(candidates, [false, true],
        reason: 'the active forced restart remains single-flight');

    forceGate.complete();
    await _settle();
    expect(candidates, [false, true, true],
        reason: 'a later transport change is retained as the next force');
    softGate.complete();
    await _settle();
    controller.dispose();
  });

  test('a stream update wins over an older in-flight connectivity check',
      () async {
    final check = Completer<Set<MatrixTransport>>();
    final transport = _FakeTransport.pending(check);
    var offline = 0;
    var candidates = 0;
    final controller = MatrixSyncRecoveryController(
      transport: transport,
      onCandidate: (_) async {
        candidates++;
      },
      onOffline: () => offline++,
    );

    controller.start();
    transport.emit({});
    await _settle();
    check.complete({MatrixTransport.wifi});
    await _settle();

    expect(offline, 1);
    expect(candidates, 0,
        reason: 'late check must not overwrite newer offline transport');
    controller.dispose();
  });

  test('transport stream errors are contained by the recovery controller',
      () async {
    final transport = _FakeTransport({MatrixTransport.wifi});
    final controller = MatrixSyncRecoveryController(
      transport: transport,
      onCandidate: (_) async {},
      onOffline: () {},
    );

    controller.start();
    await _settle();
    transport.addError(StateError('synthetic connectivity plugin error'));
    await _settle();

    controller.dispose();
  });
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

final class _FakeTransport implements MatrixTransportMonitor {
  _FakeTransport(Set<MatrixTransport> value) : _check = Future.value(value);
  _FakeTransport.pending(Completer<Set<MatrixTransport>> pending)
      : _check = pending.future;

  final Future<Set<MatrixTransport>> _check;
  final _changes = StreamController<Set<MatrixTransport>>.broadcast();

  @override
  Future<Set<MatrixTransport>> check() => _check;

  @override
  Stream<Set<MatrixTransport>> get changes => _changes.stream;

  void emit(Set<MatrixTransport> value) => _changes.add(value);
  void addError(Object error) => _changes.addError(error);
}
