import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_consumer_scope.dart';
import 'package:liuhetong_mobile/features/matrix/media_load_scheduler.dart';
import 'package:liuhetong_mobile/features/matrix/media_transfer_budget.dart';

const mib = 1024 * 1024;
Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  test('10/50/100MiB whole-operation peaks are admitted atomically', () async {
    final budget = MediaTransferBudget(maxBytes: 600 * mib);
    final first = Completer<void>(),
        second = Completer<void>(),
        third = Completer<void>();
    final a =
        budget.run(MediaTransferPlan.upload(10 * mib), () => first.future);
    final b =
        budget.run(MediaTransferPlan.upload(50 * mib), () => second.future);
    var thirdStarted = false;
    final c = budget.run(MediaTransferPlan.upload(100 * mib), () {
      thirdStarted = true;
      return third.future;
    });
    await tick();
    expect(budget.activeBytes, 240 * mib);
    expect(budget.queuedCount, 1);
    first.complete();
    await a;
    await tick();
    expect(thirdStarted, isTrue);
    expect(budget.activeBytes, 600 * mib);
    second.complete();
    third.complete();
    await Future.wait([b, c]);
    expect(budget.activeBytes, 0);
    expect(budget.peakBytes, 600 * mib);
  });

  test('default oversize has exact actionable limit, never queues', () async {
    final budget = MediaTransferBudget();
    await expectLater(
        budget.run(MediaTransferPlan.upload(50 * mib), () async {}),
        throwsA(isA<MediaTransferLimitException>()
            .having((e) => e.maximumPayloadBytes, 'limit', 48 * mib)));
    expect(budget.queuedCount, 0);
    expect(budget.activeBytes, 0);
    expect(budget.maximumUploadBytes(decodedBytes: 64 * mib), 32 * mib);
  });

  test(
      'queued cancel removes metadata; active cancel retains bytes until settle',
      () async {
    final budget = MediaTransferBudget(maxBytes: 40 * mib);
    final active = MediaConsumerScope(), queued = MediaConsumerScope();
    final settle = Completer<void>();
    final a = active.run(() =>
        budget.run(MediaTransferPlan.upload(10 * mib), () => settle.future));
    final aCheck = expectLater(a, throwsA(isA<MediaLoadCanceled>()));
    final b = queued.run(() => budget.run(MediaTransferPlan.upload(10 * mib),
        () async => fail('cancelled read')));
    final bCheck = expectLater(b, throwsA(isA<MediaLoadCanceled>()));
    await tick();
    active.cancel();
    queued.cancel();
    await bCheck;
    expect(budget.activeBytes, 40 * mib);
    expect(budget.queuedCount, 0);
    settle.complete();
    await aCheck;
    expect(budget.activeBytes, 0);
    expect(active.debugCancelListenerCount, 0);
    expect(queued.debugCancelListenerCount, 0);
  });

  test('nested work reuses reservation; detached child prevents early release',
      () async {
    final budget = MediaTransferBudget(maxBytes: 40 * mib);
    final settle = Completer<void>();
    late Future<void> child;
    await budget.run(MediaTransferPlan.upload(10 * mib), () async {
      child =
          budget.run(MediaTransferPlan.upload(10 * mib), () => settle.future);
      await tick();
      expect(budget.activeBytes, 40 * mib);
    });
    expect(budget.activeBytes, 40 * mib);
    settle.complete();
    await child;
    expect(budget.activeBytes, 0);
  });

  test(
      'nested expansion and concurrent siblings fail rather than self-deadlock',
      () async {
    final budget = MediaTransferBudget(maxBytes: 40 * mib);
    await budget.run(MediaTransferPlan.upload(10 * mib), () async {
      await expectLater(
          budget.run(MediaTransferPlan.upload(11 * mib), () async {}),
          throwsA(isA<MediaTransferLimitException>()));
      final settle = Completer<void>();
      final child =
          budget.run(MediaTransferPlan.upload(10 * mib), () => settle.future);
      await expectLater(budget.run(MediaTransferPlan.upload(1), () async {}),
          throwsA(isA<StateError>()));
      settle.complete();
      await child;
    });
    expect(budget.activeBytes, 0);
  });

  test('failure returns all categories and allows the FIFO waiter to start',
      () async {
    final budget = MediaTransferBudget(maxBytes: 100);
    final settle = Completer<void>();
    final a = budget.run(
        const MediaTransferPlan(
            sourceBytes: 20,
            ciphertextBytes: 20,
            downloadBytes: 20,
            decodedBytes: 40,
            payloadBytes: 15), () async {
      await settle.future;
      throw const FormatException('synthetic integrity failure');
    });
    final check = expectLater(a, throwsFormatException);
    var next = false;
    final b = budget.run(MediaTransferPlan.upload(25), () async {
      next = true;
    });
    await tick();
    expect(next, isFalse);
    settle.complete();
    await check;
    await b;
    expect(next, isTrue);
    expect(budget.activeBytes, 0);
  });

  test('a settled owner cannot reuse its old Zone for late work', () async {
    final budget = MediaTransferBudget(maxBytes: 40);
    late Future<void> Function() lateWork;
    await budget.run(MediaTransferPlan.upload(10), () async {
      final zone = Zone.current;
      lateWork = () =>
          zone.run(() => budget.run(MediaTransferPlan.upload(10), () async {}));
    });
    await expectLater(lateWork(), throwsStateError);
    expect(budget.activeBytes, 0);
  });
}
