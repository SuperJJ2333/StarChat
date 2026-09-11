import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_consumer_scope.dart';
import 'package:liuhetong_mobile/features/matrix/media_load_scheduler.dart';

void main() {
  test('two owners isolate cancellation and last owner cancels child',
      () async {
    final canceled = Completer<void>();
    final source = Completer<int>();
    final flight = OwnedMediaFlight<int>(() => source.future,
        childScope: MediaConsumerScope(onCancel: () => canceled.complete()));
    final a = MediaConsumerScope();
    final b = MediaConsumerScope();
    final first = flight.join(a);
    final second = flight.join(b);
    final canceledFirst = expectLater(first, throwsA(isA<MediaLoadCanceled>()));
    a.dispose();
    expect(canceled.isCompleted, isFalse);
    source.complete(7);
    await canceledFirst;
    expect(await second, 7);
    b.dispose();
  });

  test('unscoped pin survives scoped cancellation and is shared', () async {
    final source = Completer<int>();
    final flight = OwnedMediaFlight<int>(() => source.future);
    final owner = MediaConsumerScope();
    final pinned = flight.join();
    expect(identical(pinned, flight.join()), isTrue);
    final scoped = flight.join(owner);
    owner.dispose();
    await expectLater(scoped, throwsA(isA<MediaLoadCanceled>()));
    source.complete(3);
    expect(await pinned, 3);
  });

  test('last scoped owner cancels child and completion removes listeners',
      () async {
    final source = Completer<int>();
    final child = MediaConsumerScope();
    final flight =
        OwnedMediaFlight<int>(() => source.future, childScope: child);
    final owner = MediaConsumerScope();
    final future = flight.join(owner);
    owner.dispose();
    await expectLater(future, throwsA(isA<MediaLoadCanceled>()));
    expect(child.isActive, isFalse);
    expect(owner.debugCancelListenerCount, 0);
    expect(owner.debugPriorityListenerCount, 0);
    source.complete(1);
  });

  test('normal completion releases a live owner listeners', () async {
    final source = Completer<int>();
    final flight = OwnedMediaFlight<int>(() => source.future);
    final owner = MediaConsumerScope();
    final value = flight.join(owner);
    source.complete(4);
    expect(await value, 4);
    expect(owner.debugCancelListenerCount, 0);
    expect(owner.debugPriorityListenerCount, 0);
  });

  test('inactive flight rejects rejoin and notifies once after native finish',
      () async {
    final source = Completer<int>();
    var inactive = 0;
    final flight = OwnedMediaFlight<int>(() => source.future)
      ..onInactive = () => inactive++;
    final owner = MediaConsumerScope();
    final first = flight.join(owner);
    owner.dispose();
    await expectLater(first, throwsA(isA<MediaLoadCanceled>()));
    expect(inactive, 1);
    await expectLater(
        flight.join(MediaConsumerScope()), throwsA(isA<MediaLoadCanceled>()));
    source.complete(9);
    await Future<void>.delayed(Duration.zero);
    expect(inactive, 1);
    expect(flight.finished, isTrue);
  });

  test('closed scope does not invoke a new load', () async {
    final scope = MediaConsumerScope()..dispose();
    var called = false;
    await expectLater(scope.run(() async {
      called = true;
      return 1;
    }), throwsA(isA<MediaLoadCanceled>()));
    expect(called, isFalse);
  });

  test('prefetch owner promotes child priority', () async {
    final source = Completer<int>();
    final flight = OwnedMediaFlight<int>(() => source.future);
    final owner = MediaConsumerScope(priority: MediaLoadPriority.prefetch);
    final pending = flight.join(owner);
    expect(flight.childScope.priority, MediaLoadPriority.prefetch);
    owner.promote(MediaLoadPriority.interactive);
    expect(flight.childScope.priority, MediaLoadPriority.interactive);
    source.complete(1);
    await pending;
  });

  test('synchronous success and throw clean up once', () async {
    for (final source in <Future<int> Function()>[
      () => SynchronousFuture(1),
      () => throw StateError('sync throw'),
    ]) {
      var inactive = 0;
      final owner = MediaConsumerScope();
      final flight = OwnedMediaFlight<int>(source)
        ..onInactive = () => inactive++;
      if (inactive == 0) {
        await flight.join(owner).catchError((_) => 0);
      }
      expect(owner.debugCancelListenerCount, 0);
      expect(owner.debugPriorityListenerCount, 0);
      expect(inactive, 1);
    }
  });

  test('reentrant join shares the registered flight', () async {
    final held = Completer<int>();
    var calls = 0;
    late OwnedMediaFlight<int> flight;
    Future<int>? reentrant;
    final a = MediaConsumerScope();
    final b = MediaConsumerScope();
    flight = OwnedMediaFlight<int>(() {
      calls++;
      reentrant = flight.join(b);
      return held.future;
    });
    final first = flight.join(a);
    held.complete(5);
    expect(await first, 5);
    expect(await reentrant, 5);
    expect(calls, 1);
  });
}
