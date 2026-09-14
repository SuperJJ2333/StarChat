import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_outgoing_work_coordinator.dart';

MatrixOutgoingWorkItem _item({
  required String id,
  required String targetRoomId,
  required String txid,
  Future<void> Function(MatrixOutgoingWorkAttempt attempt)? prepare,
  required Future<void> Function(MatrixOutgoingWorkAttempt attempt) send,
  Future<void> Function()? release,
}) =>
    MatrixOutgoingWorkItem(
      id: id,
      targetRoomId: targetRoomId,
      txid: txid,
      prepare: prepare,
      send: (attempt) async {
        await send(attempt);
        return 'event-$txid';
      },
      release: release,
    );

void main() {
  test('returns after registration while preparation remains held', () async {
    final preparation = Completer<void>();
    final sent = Completer<void>();
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');

    final job = await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'camera-1',
      items: [
        _item(
          id: 'video',
          targetRoomId: '!room:test',
          txid: 'outgoing-camera-1-0-0',
          prepare: (_) => preparation.future,
          send: (_) {
            sent.complete();
            return Future.value();
          },
        ),
      ],
    ));

    expect(job.items.single.state, MatrixOutgoingWorkState.preparing);
    expect(sent.isCompleted, isFalse);
    preparation.complete();
    await sent.future;
    await coordinator.drain();
    expect(coordinator.job('camera-1')!.items.single.state,
        MatrixOutgoingWorkState.sent);
  });

  test('revocation after preparation prevents the held send from starting',
      () async {
    final enteredSend = Completer<void>();
    final releaseSend = Completer<void>();
    var networkSends = 0;
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');

    await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'logout-1',
      items: [
        _item(
          id: 'file',
          targetRoomId: '!room:test',
          txid: 'outgoing-logout-1-0-0',
          send: (attempt) async {
            enteredSend.complete();
            await releaseSend.future;
            attempt.ensureActive();
            networkSends++;
          },
        ),
      ],
    ));

    await enteredSend.future;
    coordinator.revoke('logout');
    releaseSend.complete();
    await coordinator.drain();

    expect(networkSends, 0);
    expect(coordinator.job('logout-1')!.items.single.state,
        MatrixOutgoingWorkState.canceled);
  });

  test('retries only failed target items with their original transaction ids',
      () async {
    final calls = <String>[];
    var bAttempts = 0;
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');
    await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'forward-1',
      items: [
        _item(
          id: 'a-text',
          targetRoomId: '!a:test',
          txid: 'outgoing-forward-1-0-0',
          send: (attempt) {
            calls.add('a:${attempt.txid}');
            return Future.value();
          },
        ),
        _item(
          id: 'b-image',
          targetRoomId: '!b:test',
          txid: 'outgoing-forward-1-1-0',
          send: (attempt) async {
            calls.add('b:${attempt.txid}');
            if (bAttempts++ == 0) throw StateError('offline');
          },
        ),
      ],
    ));
    await coordinator.drain();

    expect(coordinator.job('forward-1')!.items.map((item) => item.state), [
      MatrixOutgoingWorkState.sent,
      MatrixOutgoingWorkState.failed,
    ]);
    expect(coordinator.job('forward-1')!.targetState('!a:test'),
        MatrixOutgoingTargetState.sent);
    expect(coordinator.job('forward-1')!.targetState('!b:test'),
        MatrixOutgoingTargetState.failed);

    await coordinator.retryFailed('forward-1');
    await coordinator.drain();

    expect(calls, [
      'a:outgoing-forward-1-0-0',
      'b:outgoing-forward-1-1-0',
      'b:outgoing-forward-1-1-0',
    ]);
    expect(
        coordinator
            .job('forward-1')!
            .items
            .every((item) => item.state == MatrixOutgoingWorkState.sent),
        isTrue);
  });

  test('same job id is registered once and projects pending work by target',
      () async {
    final release = Completer<void>();
    var starts = 0;
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');
    final work = MatrixOutgoingWorkJob(
      id: 'same-confirmation',
      items: [
        _item(
          id: 'text',
          targetRoomId: '!target:test',
          txid: 'outgoing-same-confirmation-0-0',
          send: (_) async {
            starts++;
            await release.future;
          },
        ),
      ],
    );

    await coordinator.enqueue(work);
    await coordinator.enqueue(work);
    expect(starts, 1);
    expect(coordinator.itemsForRoom('!target:test').single.id, 'text');
    expect(coordinator.itemsForRoom('!target:test').single.state,
        MatrixOutgoingWorkState.sending);
    release.complete();
    await coordinator.drain();
  });

  test('serializes held preparation and bounds held transfers', () async {
    final firstPreparation = Completer<void>();
    final secondPreparationStarted = Completer<void>();
    final firstSend = Completer<void>();
    final releaseTransfers = Completer<void>();
    var startedTransfers = 0;
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');

    await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'bounded',
      items: [
        _item(
          id: 'first-prepare',
          targetRoomId: '!a:test',
          txid: 'outgoing-bounded-0-0',
          prepare: (_) => firstPreparation.future,
          send: (_) => firstSend.future,
        ),
        _item(
          id: 'second-prepare',
          targetRoomId: '!b:test',
          txid: 'outgoing-bounded-1-0',
          prepare: (_) {
            secondPreparationStarted.complete();
            return Future.value();
          },
          send: (_) => Future.value(),
        ),
        for (var index = 0; index < 4; index++)
          _item(
            id: 'held-$index',
            targetRoomId: '!$index:test',
            txid: 'outgoing-bounded-${index + 2}-0',
            send: (_) {
              startedTransfers++;
              return releaseTransfers.future;
            },
          ),
      ],
    ));

    await Future<void>.delayed(Duration.zero);
    expect(secondPreparationStarted.isCompleted, isFalse);
    expect(startedTransfers, 3);
    firstPreparation.complete();
    await secondPreparationStarted.future;
    releaseTransfers.complete();
    firstSend.complete();
    await coordinator.drain();
  });

  test('revocation while preparation is held never starts its send', () async {
    final releasePreparation = Completer<void>();
    var sends = 0;
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');
    await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'revoke-preparation',
      items: [
        _item(
          id: 'video',
          targetRoomId: '!room:test',
          txid: 'outgoing-revoke-preparation-0-0',
          prepare: (_) => releasePreparation.future,
          send: (_) async => sends++,
        ),
      ],
    ));

    coordinator.revoke('account switch');
    releasePreparation.complete();
    await coordinator.drain();
    expect(sends, 0);
    expect(coordinator.job('revoke-preparation')!.items.single.state,
        MatrixOutgoingWorkState.canceled);
  });

  test('same job id keeps its original payload and terminal release runs once',
      () async {
    var originalSends = 0;
    var replacementSends = 0;
    var releases = 0;
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');
    final original = MatrixOutgoingWorkJob(
      id: 'immutable-job',
      items: [
        _item(
          id: 'image',
          targetRoomId: '!target:test',
          txid: 'outgoing-immutable-job-0-0',
          send: (_) async => originalSends++,
          release: () async => releases++,
        ),
      ],
    );
    final replacement = MatrixOutgoingWorkJob(
      id: 'immutable-job',
      items: [
        _item(
          id: 'replacement',
          targetRoomId: '!other:test',
          txid: 'outgoing-immutable-job-9-0',
          send: (_) async => replacementSends++,
        ),
      ],
    );

    final accepted = await coordinator.enqueue(original);
    final duplicate = await coordinator.enqueue(replacement);
    await coordinator.drain();

    expect(identical(accepted, duplicate), isTrue);
    expect(originalSends, 1);
    expect(replacementSends, 0);
    expect(releases, 1);
  });

  test('revocation cancels a prepared item waiting behind held transfers',
      () async {
    final releaseTransfers = Completer<void>();
    final prepared = Completer<void>();
    var delayedSendStarts = 0;
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');
    await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'revoke-ready',
      items: [
        for (var index = 0; index < 3; index++)
          _item(
            id: 'held-$index',
            targetRoomId: '!held-$index:test',
            txid: 'outgoing-revoke-ready-$index-0',
            send: (_) => releaseTransfers.future,
          ),
        _item(
          id: 'prepared',
          targetRoomId: '!prepared:test',
          txid: 'outgoing-revoke-ready-3-0',
          prepare: (_) {
            prepared.complete();
            return Future.value();
          },
          send: (_) async => delayedSendStarts++,
        ),
      ],
    ));
    await prepared.future;
    await Future<void>.delayed(Duration.zero);
    expect(coordinator.job('revoke-ready')!.items.last.state,
        MatrixOutgoingWorkState.ready);

    coordinator.revoke('logout');
    releaseTransfers.complete();
    await coordinator.drain();

    expect(delayedSendStarts, 0);
    expect(coordinator.job('revoke-ready')!.items.last.state,
        MatrixOutgoingWorkState.canceled);
  });

  test('revocation releases a failed payload that remains retryable beforehand',
      () async {
    var releases = 0;
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');
    await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'failed-cleanup',
      items: [
        _item(
          id: 'image',
          targetRoomId: '!target:test',
          txid: 'outgoing-failed-cleanup-0-0',
          send: (_) async => throw StateError('offline'),
          release: () async => releases++,
        ),
      ],
    ));
    await coordinator.drain();
    expect(coordinator.job('failed-cleanup')!.items.single.state,
        MatrixOutgoingWorkState.failed);
    expect(releases, 0);

    coordinator.revoke('logout');
    await coordinator.drain();

    expect(coordinator.job('failed-cleanup')!.items.single.state,
        MatrixOutgoingWorkState.canceled);
    expect(releases, 1);
  });

  test('dispose does not notify listeners when a held operation settles',
      () async {
    final releaseSend = Completer<void>();
    var notifications = 0;
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test')
      ..addListener(() => notifications++);
    await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'dispose-held',
      items: [
        _item(
          id: 'file',
          targetRoomId: '!target:test',
          txid: 'outgoing-dispose-held-0-0',
          send: (_) => releaseSend.future,
        ),
      ],
    ));
    notifications = 0;

    coordinator.dispose();
    releaseSend.complete();
    await coordinator.drain();

    expect(notifications, 0);
  });

  test('prepares a shared source once when retrying only its failed send',
      () async {
    var preparations = 0;
    var sends = 0;
    var releases = 0;
    final source = MatrixOutgoingWorkSource(
      id: 'camera-output',
      retainedBytes: 20 * 1024 * 1024,
      prepare: (_) async => preparations++,
      release: () async => releases++,
    );
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');
    await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'camera-retry',
      source: source,
      items: [
        _item(
          id: 'video',
          targetRoomId: '!target:test',
          txid: 'outgoing-camera-retry-0-0',
          send: (_) async {
            if (sends++ == 0) throw StateError('offline');
          },
        ),
      ],
    ));
    await coordinator.drain();
    await coordinator.retryFailed('camera-retry');
    await coordinator.drain();

    expect(preparations, 1);
    expect(sends, 2);
    expect(releases, 1);
  });

  test('holds at most one prepared source when uploads occupy all slots',
      () async {
    final releaseUploads = Completer<void>();
    final prepared = <String>[];
    final coordinator = MatrixOutgoingWorkCoordinator(
      accountId: '@me:test',
      maxReadySources: 1,
    );
    for (var index = 0; index < 5; index++) {
      final sourceId = 'source-$index';
      await coordinator.enqueue(MatrixOutgoingWorkJob(
        id: 'backpressure-$index',
        source: MatrixOutgoingWorkSource(
          id: sourceId,
          retainedBytes: 20 * 1024 * 1024,
          prepare: (_) async => prepared.add(sourceId),
          release: () async {},
        ),
        items: [
          _item(
            id: 'item-$index',
            targetRoomId: '!$index:test',
            txid: 'outgoing-backpressure-$index-0',
            send: (_) => releaseUploads.future,
          ),
        ],
      ));
    }
    await Future<void>.delayed(Duration.zero);

    expect(prepared, ['source-0', 'source-1', 'source-2', 'source-3']);
    expect(coordinator.readySourceCount, 1);
    releaseUploads.complete();
    await coordinator.drain();
  });

  test(
      'marks a released preparation ready before admitting another waiting source',
      () async {
    final releaseFirstPreparation = Completer<void>();
    final prepared = <String>[];
    final uploadReleases = List.generate(5, (_) => Completer<void>());
    final coordinator = MatrixOutgoingWorkCoordinator(
      accountId: '@me:test',
      maxReadySources: 1,
    );

    for (var index = 0; index < 5; index++) {
      final sourceId = 'synchronous-source-$index';
      await coordinator.enqueue(MatrixOutgoingWorkJob(
        id: 'strict-backpressure-$index',
        source: MatrixOutgoingWorkSource(
          id: sourceId,
          retainedBytes: 1,
          prepare: (_) async {
            prepared.add(sourceId);
            if (index == 0) await releaseFirstPreparation.future;
          },
          release: () async {},
        ),
        items: [
          _item(
            id: 'item-$index',
            targetRoomId: '!$index:test',
            txid: 'outgoing-strict-backpressure-$index-0',
            send: (_) => uploadReleases[index].future,
          ),
        ],
      ));
    }

    releaseFirstPreparation.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(prepared, [
      'synchronous-source-0',
      'synchronous-source-1',
      'synchronous-source-2',
      'synchronous-source-3',
    ]);
    expect(coordinator.readySourceCount, 1);

    uploadReleases[0].complete();
    await Future<void>.delayed(Duration.zero);
    expect(prepared, hasLength(5));

    for (final release in uploadReleases.skip(1)) {
      release.complete();
    }
    await coordinator.drain();
  });

  test('accounts for one shared source separately from target metadata',
      () async {
    final release = Completer<void>();
    final coordinator = MatrixOutgoingWorkCoordinator(
      accountId: '@me:test',
      maxOutstandingItems: 128,
      maxRetainedSourceBytes: 10,
    );
    await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'fanout',
      source: MatrixOutgoingWorkSource(
        id: 'edited-image',
        retainedBytes: 8,
        release: () async {},
      ),
      items: [
        for (var index = 0; index < 5; index++)
          _item(
            id: 'target-$index',
            targetRoomId: '!$index:test',
            txid: 'outgoing-fanout-$index-0',
            send: (_) => release.future,
          ),
      ],
    ));

    expect(
      coordinator.enqueue(MatrixOutgoingWorkJob(
        id: 'too-much-source',
        source: MatrixOutgoingWorkSource(
          id: 'next-image',
          retainedBytes: 3,
          release: () async {},
        ),
        items: [
          _item(
            id: 'target',
            targetRoomId: '!next:test',
            txid: 'outgoing-next-0-0',
            send: (_) async {},
          ),
        ],
      )),
      throwsA(isA<MatrixOutgoingWorkCapacityException>()),
    );
    release.complete();
    await coordinator.drain();
  });

  test('rejects a batch atomically before owning any of its sources', () async {
    var releases = 0;
    final coordinator = MatrixOutgoingWorkCoordinator(
      accountId: '@me:test',
      maxOutstandingItems: 1,
    );
    final firstSource = MatrixOutgoingWorkSource(
      id: 'first',
      retainedBytes: 1,
      release: () async => releases++,
    );
    final secondSource = MatrixOutgoingWorkSource(
      id: 'second',
      retainedBytes: 1,
      release: () async => releases++,
    );

    await expectLater(
      coordinator.enqueueBatch([
        MatrixOutgoingWorkJob(
          id: 'first-job',
          source: firstSource,
          items: [
            _item(
              id: 'first-item',
              targetRoomId: '!first:test',
              txid: 'outgoing-first-0-0',
              send: (_) async {},
            ),
          ],
        ),
        MatrixOutgoingWorkJob(
          id: 'second-job',
          source: secondSource,
          items: [
            _item(
              id: 'second-item',
              targetRoomId: '!second:test',
              txid: 'outgoing-second-0-0',
              send: (_) async {},
            ),
          ],
        ),
      ]),
      throwsA(isA<MatrixOutgoingWorkCapacityException>()),
    );
    expect(coordinator.job('first-job'), isNull);
    expect(coordinator.job('second-job'), isNull);
    expect(releases, 0);
    await firstSource.release();
    await secondSource.release();
    expect(releases, 2);
  });

  test('records the actual acknowledged event id in the pending projection',
      () async {
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');
    final createdAt = DateTime.utc(2026, 9, 12, 12);
    final job = await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'event-ack',
      createdAt: createdAt,
      source: MatrixOutgoingWorkSource(id: 'text', retainedBytes: 0),
      items: [
        MatrixOutgoingWorkItem(
          id: 'item',
          targetRoomId: '!room:test',
          txid: 'outgoing-event-ack-0-0',
          presentation: MatrixOutgoingWorkPresentation(
            kind: MatrixOutgoingPresentationKind.text,
            text: 'fixed selected text',
            createdAt: createdAt,
          ),
          send: (_) async => r'$actual-event',
        ),
      ],
    ));
    await coordinator.drain();

    expect(job.createdAt, createdAt);
    expect(job.items.single.eventId, r'$actual-event');
    expect(job.items.single.presentation.text, 'fixed selected text');
  });

  test('retains successful pending projection until event-id or txid echo',
      () async {
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');
    final job = await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'echo-retention',
      source: MatrixOutgoingWorkSource(id: 'text', retainedBytes: 0),
      items: [
        MatrixOutgoingWorkItem(
          id: 'event-id-only',
          targetRoomId: '!room:test',
          txid: 'outgoing-echo-event-id-0',
          send: (_) async => r'$event-id-only',
        ),
        MatrixOutgoingWorkItem(
          id: 'txid',
          targetRoomId: '!room:test',
          txid: 'outgoing-echo-txid-1',
          send: (_) async => r'$event-with-txid',
        ),
      ],
    ));
    await coordinator.drain();

    // HTTP acknowledgement alone is not a timeline row; route reconstruction
    // must still show both bubbles while the SDK echo is delayed.
    expect(coordinator.itemsForRoom('!room:test'), hasLength(2));
    coordinator.acknowledgeEcho(eventId: r'$event-id-only');
    expect(coordinator.itemsForRoom('!room:test').single.id, 'txid');
    coordinator.acknowledgeEcho(transactionId: 'outgoing-echo-txid-1');
    expect(coordinator.itemsForRoom('!room:test'), isEmpty);
    expect(job.items.every((item) => item.eventId != null), isTrue);
  });

  test('falls back from an unmatched transaction id to its event id', () async {
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');
    await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'echo-id-fallback',
      source: MatrixOutgoingWorkSource(id: 'source', retainedBytes: 1),
      items: [
        _item(
          id: 'target',
          targetRoomId: '!target:test',
          txid: 'outgoing-correct',
          send: (_) async {},
        ),
      ],
    ));
    await coordinator.drain();

    coordinator.acknowledgeEchoes([
      const MatrixOutgoingWorkEcho(
        eventId: 'event-outgoing-correct',
        transactionId: 'outgoing-stale',
      ),
    ]);

    expect(coordinator.itemsForRoom('!target:test'), isEmpty);
  });

  test('an echo during failed preparation settles the job as sent', () async {
    final releasePreparation = Completer<void>();
    var released = 0;
    var sends = 0;
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');
    await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'preparation-echo-wins',
      source: MatrixOutgoingWorkSource(
        id: 'source',
        retainedBytes: 1,
        prepare: (_) async {
          await releasePreparation.future;
          throw StateError('local preparation failed after sync');
        },
        release: () async => released++,
      ),
      items: [
        _item(
          id: 'target',
          targetRoomId: '!target:test',
          txid: 'outgoing-preparation-echo',
          send: (_) async => sends++,
        ),
      ],
    ));

    coordinator.acknowledgeEchoes([
      const MatrixOutgoingWorkEcho(
        roomId: '!target:test',
        transactionId: 'outgoing-preparation-echo',
        eventId: r'$stored-during-preparation',
      ),
    ]);
    releasePreparation.complete();
    await coordinator.drain();

    expect(coordinator.itemsForRoom('!target:test'), isEmpty);
    expect(sends, 0);
    expect(released, 1);
  });

  test('counts sent work until its timeline echo releases admission capacity',
      () async {
    final coordinator = MatrixOutgoingWorkCoordinator(
      accountId: '@me:test',
      maxOutstandingItems: 1,
    );
    await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'first',
      source: MatrixOutgoingWorkSource(id: 'first-source', retainedBytes: 0),
      items: [
        _item(
          id: 'first-item',
          targetRoomId: '!first:test',
          txid: 'outgoing-first',
          send: (_) async => r'$first',
        ),
      ],
    ));
    await coordinator.drain();
    final next = MatrixOutgoingWorkJob(
      id: 'next',
      source: MatrixOutgoingWorkSource(id: 'next-source', retainedBytes: 0),
      items: [
        _item(
          id: 'next-item',
          targetRoomId: '!next:test',
          txid: 'outgoing-next',
          send: (_) async => r'$next',
        ),
      ],
    );
    await expectLater(
      coordinator.enqueue(next),
      throwsA(isA<MatrixOutgoingWorkCapacityException>()),
    );
    coordinator.acknowledgeEcho(transactionId: 'outgoing-first');
    await coordinator.enqueue(next);
    await coordinator.drain();
  });

  test('keeps an event-id echo that arrives before its send result', () async {
    final enteredSend = Completer<void>();
    final releaseSend = Completer<void>();
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');
    await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'early-event-id',
      source: MatrixOutgoingWorkSource(id: 'source', retainedBytes: 0),
      items: [
        MatrixOutgoingWorkItem(
          id: 'item',
          targetRoomId: '!target:test',
          txid: 'outgoing-early-event-id',
          send: (_) async {
            enteredSend.complete();
            await releaseSend.future;
            return r'$synced-before-http';
          },
        ),
      ],
    ));
    await enteredSend.future;
    coordinator.acknowledgeEchoes(const [
      MatrixOutgoingWorkEcho(
        roomId: '!target:test',
        eventId: r'$synced-before-http',
      ),
    ]);
    releaseSend.complete();
    await coordinator.drain();

    expect(coordinator.itemsForRoom('!target:test'), isEmpty);
  });

  test('treats a synchronized transaction echo as success when send throws',
      () async {
    final enteredSend = Completer<void>();
    final releaseSend = Completer<void>();
    var released = 0;
    var sends = 0;
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');
    await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'echo-wins-over-http-failure',
      source: MatrixOutgoingWorkSource(
          id: 'source', retainedBytes: 1, release: () async => released++),
      items: [
        _item(
          id: 'item',
          targetRoomId: '!target:test',
          txid: 'outgoing-synced-before-http-failure',
          send: (_) async {
            sends++;
            enteredSend.complete();
            await releaseSend.future;
            throw StateError('HTTP acknowledgement lost');
          },
        ),
      ],
    ));
    await enteredSend.future;
    coordinator.acknowledgeEcho(
        transactionId: 'outgoing-synced-before-http-failure');
    expect(released, 0,
        reason:
            'An in-flight SDK request still owns its source until it ends.');
    releaseSend.complete();
    await coordinator.drain();
    await coordinator.retryFailed('echo-wins-over-http-failure');
    await coordinator.drain();

    expect(coordinator.itemsForRoom('!target:test'), isEmpty);
    expect(released, 1);
    expect(sends, 1, reason: 'The SDK-confirmed target is never retried.');
  });

  test('converges a failed send when its later transaction echo is stored',
      () async {
    var released = 0;
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');
    await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'late-echo-after-failure',
      source: MatrixOutgoingWorkSource(
          id: 'source', retainedBytes: 1, release: () async => released++),
      items: [
        _item(
          id: 'item',
          targetRoomId: '!target:test',
          txid: 'outgoing-late-synced',
          send: (_) async => throw StateError('HTTP timeout'),
        ),
      ],
    ));
    await coordinator.drain();
    expect(coordinator.itemsForRoom('!target:test').single.state,
        MatrixOutgoingWorkState.failed);

    coordinator.acknowledgeEcho(transactionId: 'outgoing-late-synced');

    expect(coordinator.itemsForRoom('!target:test'), isEmpty);
    expect(released, 1);
  });

  test('rejected admission leaves temporary source cleanup to its caller',
      () async {
    var releases = 0;
    final source = MatrixOutgoingWorkSource(
      id: 'unaccepted-camera',
      retainedBytes: 2,
      release: () async => releases++,
    );
    final coordinator = MatrixOutgoingWorkCoordinator(
      accountId: '@me:test',
      maxRetainedSourceBytes: 1,
    );

    await expectLater(
      coordinator.enqueue(MatrixOutgoingWorkJob(
        id: 'rejected',
        source: source,
        items: [
          _item(
            id: 'item',
            targetRoomId: '!target:test',
            txid: 'outgoing-rejected-0-0',
            send: (_) async {},
          ),
        ],
      )),
      throwsA(isA<MatrixOutgoingWorkCapacityException>()),
    );
    expect(releases, 0);
    await source.release();
    expect(releases, 1);
  });
  test('rejects a deferred source that can never fit the preparation budget',
      () async {
    final coordinator = MatrixOutgoingWorkCoordinator(
      accountId: '@me:test',
      maxRetainedSourceBytes: 10,
    );
    final source = MatrixOutgoingWorkSource(
      id: 'oversized-deferred',
      retainedBytes: 0,
      preparationBytes: 11,
      prepare: (_) async {},
    );

    await expectLater(
      coordinator.enqueue(MatrixOutgoingWorkJob(
        id: 'oversized-deferred-job',
        source: source,
        items: [
          _item(
            id: 'item',
            targetRoomId: '!room:test',
            txid: 'outgoing-oversized-deferred-0',
            send: (_) async {},
          ),
        ],
      )),
      throwsA(isA<MatrixOutgoingWorkCapacityException>()),
    );
    expect(coordinator.job('oversized-deferred-job'), isNull);
  });
  test('defers source reservations until bounded preparation begins', () async {
    const reservation = 10;
    final gates = List.generate(9, (_) => Completer<void>());
    final prepared = <int>[];
    final coordinator = MatrixOutgoingWorkCoordinator(
      accountId: '@me:test',
      maxRetainedSourceBytes: reservation,
      maxConcurrentTransfers: 1,
      maxReadySources: 1,
    );
    final jobs = <MatrixOutgoingWorkJob>[
      for (var index = 0; index < gates.length; index++)
        MatrixOutgoingWorkJob(
          id: 'deferred-$index',
          source: MatrixOutgoingWorkSource(
            id: 'deferred-source-$index',
            retainedBytes: 0,
            preparationBytes: reservation,
            prepare: (_) async {
              prepared.add(index);
              await gates[index].future;
            },
          ),
          items: [
            _item(
              id: 'item-$index',
              targetRoomId: '!$index:test',
              txid: 'outgoing-deferred-$index-0',
              send: (_) async {},
            ),
          ],
        ),
    ];

    await coordinator.enqueueBatch(jobs);
    expect(coordinator.retainedSourceBytes, reservation);
    expect(prepared, [0]);
    expect(jobs.every((job) => coordinator.job(job.id) != null), isTrue,
        reason: 'All lightweight deferred handles are admitted atomically.');

    for (var index = 0; index < gates.length; index++) {
      gates[index].complete();
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.retainedSourceBytes, lessThanOrEqualTo(reservation));
    }
    await coordinator.drain();
    expect(prepared, List<int>.generate(9, (index) => index));
    expect(coordinator.retainedSourceBytes, 0);
  });
}
