import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_verification_service.dart';
import 'package:matrix/matrix.dart';

final class FakeSasRequest implements MatrixSasRequestHandle {
  int accepts = 0;
  int continues = 0;
  int confirmations = 0;
  int rejects = 0;
  int disposals = 0;
  Completer<void>? acceptBlocker;
  final Completer<void> acceptStarted = Completer<void>();

  @override
  Future<void> accept() async {
    accepts++;
    if (!acceptStarted.isCompleted) acceptStarted.complete();
    await acceptBlocker?.future;
  }

  @override
  Future<void> continueSas() async => continues++;

  @override
  Future<void> confirmSas() async => confirmations++;

  @override
  Future<void> reject() async => rejects++;

  @override
  void dispose() => disposals++;
}

void main() {
  test(
      'dispose drains asynchronous incoming setup and cancels its subscription',
      () async {
    var streamCancels = 0;
    var streamListens = 0;
    final incoming = StreamController<MatrixSasRequestHandle>.broadcast(
      onListen: () => streamListens++,
      onCancel: () => streamCancels++,
    );
    final suspendStarted = Completer<void>();
    final allowSuspend = Completer<void>();
    final matrix = MatrixSdkE2eeClient(
      Client('verification'),
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async {
        suspendStarted.complete();
        await allowSuspend.future;
      },
      resumeClient: () async => Client('resumed-verification'),
    );
    final suspension = matrix.suspend();
    await suspendStarted.future;
    final service = MatrixVerificationService(
      matrix,
      incomingRequests: () => incoming.stream,
    );
    final listen = service.listenForIncoming((_) {});
    final dispose = service.dispose();

    allowSuspend.complete();
    await suspension;
    await listen;
    await dispose;

    expect(streamListens, streamCancels);
    await incoming.close();
  });

  test('incoming callback exposes only immutable state and an opaque id',
      () async {
    final incoming = StreamController<MatrixSasRequestHandle>.broadcast();
    final matrix = MatrixSdkE2eeClient(
      Client('verification'),
      homeserver: Uri.parse('https://matrix.test'),
    );
    final service = MatrixVerificationService(
      matrix,
      incomingRequests: () => incoming.stream,
      requestIdFactory: () => 'opaque-request-1',
    );
    final snapshots = <MatrixVerificationRequestSnapshot>[];
    await service.listenForIncoming(snapshots.add);

    final request = FakeSasRequest();
    incoming.add(request);
    await Future<void>.delayed(Duration.zero);

    expect(snapshots, [
      const MatrixVerificationRequestSnapshot(
        requestId: 'opaque-request-1',
        phase: MatrixVerificationRequestPhase.incoming,
      ),
    ]);
    expect(snapshots.single, isNot(isA<MatrixSasRequestHandle>()));
    await incoming.close();
    await service.dispose();
  });

  test('a superseded incoming request id fails closed', () async {
    final incoming = StreamController<MatrixSasRequestHandle>.broadcast();
    var nextId = 0;
    final service = MatrixVerificationService(
      MatrixSdkE2eeClient(
        Client('verification'),
        homeserver: Uri.parse('https://matrix.test'),
      ),
      incomingRequests: () => incoming.stream,
      requestIdFactory: () => 'request-${++nextId}',
    );
    final snapshots = <MatrixVerificationRequestSnapshot>[];
    await service.listenForIncoming(snapshots.add);
    final first = FakeSasRequest();
    final second = FakeSasRequest();

    incoming.add(first);
    await Future<void>.delayed(Duration.zero);
    incoming.add(second);
    await Future<void>.delayed(Duration.zero);

    expect(first.disposals, 1);
    await expectLater(service.accept('request-1'), throwsStateError);
    await service.accept('request-2');
    expect(first.accepts, 0);
    expect(second.accepts, 1);
    await incoming.close();
    await service.dispose();
  });

  test('incoming replacement waits for the active SAS action to drain',
      () async {
    final incoming = StreamController<MatrixSasRequestHandle>.broadcast();
    var nextId = 0;
    final service = MatrixVerificationService(
      MatrixSdkE2eeClient(
        Client('verification'),
        homeserver: Uri.parse('https://matrix.test'),
      ),
      incomingRequests: () => incoming.stream,
      requestIdFactory: () => 'request-${++nextId}',
    );
    final snapshots = <MatrixVerificationRequestSnapshot>[];
    await service.listenForIncoming(snapshots.add);
    final first = FakeSasRequest()..acceptBlocker = Completer<void>();
    final second = FakeSasRequest();
    incoming.add(first);
    await Future<void>.delayed(Duration.zero);
    final action = service.accept('request-1');
    await first.acceptStarted.future;

    incoming.add(second);
    await Future<void>.delayed(Duration.zero);

    expect(first.disposals, 0);
    expect(snapshots, hasLength(1));
    first.acceptBlocker!.complete();
    await action;
    await Future<void>.delayed(Duration.zero);

    expect(first.disposals, 1);
    expect(snapshots.map((state) => state.phase), [
      MatrixVerificationRequestPhase.incoming,
      MatrixVerificationRequestPhase.revoked,
      MatrixVerificationRequestPhase.incoming,
    ]);
    await service.accept('request-2');
    expect(second.accepts, 1);
    await incoming.close();
    await service.dispose();
  });

  test('incoming queued before suspend is revoked without being published',
      () async {
    final incoming = StreamController<MatrixSasRequestHandle>.broadcast();
    var nextId = 0;
    final matrix = MatrixSdkE2eeClient(
      Client('verification'),
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async {},
    );
    final service = MatrixVerificationService(
      matrix,
      incomingRequests: () => incoming.stream,
      requestIdFactory: () => 'request-${++nextId}',
    );
    final snapshots = <MatrixVerificationRequestSnapshot>[];
    await service.listenForIncoming(snapshots.add);
    final first = FakeSasRequest()..acceptBlocker = Completer<void>();
    final queued = FakeSasRequest();
    incoming.add(first);
    await Future<void>.delayed(Duration.zero);
    final action = service.accept('request-1');
    await first.acceptStarted.future;

    incoming.add(queued);
    await Future<void>.delayed(Duration.zero);
    final transition = matrix.suspend();
    first.acceptBlocker!.complete();
    await action;
    await transition;

    expect(queued.disposals, 1);
    expect(
      snapshots.where(
        (state) => state.phase == MatrixVerificationRequestPhase.incoming,
      ),
      hasLength(1),
    );
    await incoming.close();
    await service.dispose();
  });

  test('an opaque request id is never reused after revocation', () async {
    final incoming = StreamController<MatrixSasRequestHandle>.broadcast();
    final service = MatrixVerificationService(
      MatrixSdkE2eeClient(
        Client('verification'),
        homeserver: Uri.parse('https://matrix.test'),
      ),
      incomingRequests: () => incoming.stream,
      requestIdFactory: () => 'reused-id',
    );
    await service.listenForIncoming((_) {});
    final first = FakeSasRequest();
    final collision = FakeSasRequest();

    incoming.add(first);
    await Future<void>.delayed(Duration.zero);
    incoming.add(collision);
    await Future<void>.delayed(Duration.zero);

    expect(first.disposals, 1);
    expect(collision.disposals, 1);
    await expectLater(service.accept('reused-id'), throwsStateError);
    await incoming.close();
    await service.dispose();
  });

  for (final lifecycle in <String>['suspend', 'clear']) {
    test('$lifecycle revokes incoming SAS and drains its in-flight action',
        () async {
      final incoming = StreamController<MatrixSasRequestHandle>.broadcast();
      final lifecycleEvents = <String>[];
      final matrix = MatrixSdkE2eeClient(
        Client('verification'),
        homeserver: Uri.parse('https://matrix.test'),
        suspendClient: (_) async => lifecycleEvents.add('suspend'),
        clearClientData: (_) async => lifecycleEvents.add('clear'),
      );
      final service = MatrixVerificationService(
        matrix,
        incomingRequests: () => incoming.stream,
        requestIdFactory: () => 'request-1',
      );
      final snapshots = <MatrixVerificationRequestSnapshot>[];
      await service.listenForIncoming(snapshots.add);
      final request = FakeSasRequest()..acceptBlocker = Completer<void>();
      incoming.add(request);
      await Future<void>.delayed(Duration.zero);
      final action = service.accept('request-1');
      await request.acceptStarted.future;

      final transition = lifecycle == 'suspend'
          ? matrix.suspend()
          : matrix.clearLocalChatData();
      await Future<void>.delayed(Duration.zero);
      expect(request.disposals, 0);
      expect(lifecycleEvents, isEmpty);
      expect(snapshots.last.phase, MatrixVerificationRequestPhase.revoked);
      await expectLater(service.reject('request-1'), throwsStateError);
      final late = FakeSasRequest();
      incoming.add(late);
      await Future<void>.delayed(Duration.zero);
      expect(late.disposals, 1);

      request.acceptBlocker!.complete();
      await action;
      await transition;

      expect(request.disposals, 1);
      expect(lifecycleEvents, [lifecycle]);
      expect(snapshots.last.phase, MatrixVerificationRequestPhase.revoked);
      await incoming.close();
      await service.dispose();
    });
  }
}
