import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/video_playback_arbiter.dart';

void main() {
  test('third contender waits for a held previous pause before playing',
      () async {
    final arbiter = VideoPlaybackArbiter();
    final firstPauseRelease = Completer<void>();
    final pauses = <String>[];
    final first = arbiter.reserve(Object(), () async {
      pauses.add('first');
      await firstPauseRelease.future;
    });
    final second = arbiter.reserve(Object(), () async => pauses.add('second'));
    final third = arbiter.reserve(Object(), () async => pauses.add('third'));

    expect(first.isCurrent, isFalse);
    expect(second.isCurrent, isFalse);
    expect(third.isCurrent, isTrue);
    var thirdReady = false;
    third.waitUntilReady().then((_) => thirdReady = true);
    await Future<void>.delayed(Duration.zero);
    expect(thirdReady, isFalse);

    firstPauseRelease.complete();
    await third.waitUntilReady();
    expect(pauses, ['first', 'second']);
  });

  test('cancelling a pending reservation cannot become current later',
      () async {
    final arbiter = VideoPlaybackArbiter();
    final releaseFirstPause = Completer<void>();
    final first = arbiter.reserve(Object(), () => releaseFirstPause.future);
    final pending = arbiter.reserve(Object(), () async {});
    pending.release();
    releaseFirstPause.complete();
    await pending.waitUntilReady();

    expect(first.isCurrent, isFalse);
    expect(pending.isCurrent, isFalse);
  });

  test('third contender remains blocked after a pending owner cancels',
      () async {
    final arbiter = VideoPlaybackArbiter();
    final releaseFirstPause = Completer<void>();
    arbiter.reserve(Object(), () => releaseFirstPause.future);
    final pending = arbiter.reserve(Object(), () async {});
    pending.release();
    final third = arbiter.reserve(Object(), () async {});
    var ready = false;
    third.waitUntilReady().then((_) => ready = true);
    await Future<void>.delayed(Duration.zero);
    expect(ready, isFalse);

    releaseFirstPause.complete();
    await third.waitUntilReady();
    expect(third.isCurrent, isTrue);
  });

  test('late old release cannot invalidate a replacement reservation', () async {
    final arbiter = VideoPlaybackArbiter();
    final first = arbiter.reserve(Object(), () async {});
    final replacement = arbiter.reserve(Object(), () async {});
    await replacement.waitUntilReady();
    first.release();

    expect(replacement.isCurrent, isTrue);
  });

  test('pause failure reaches the requester before it may play', () async {
    final arbiter = VideoPlaybackArbiter();
    arbiter.reserve(Object(), () async => throw StateError('pause failed'));
    final next = arbiter.reserve(Object(), () async {});

    await expectLater(next.waitUntilReady(), throwsStateError);
    expect(next.isCurrent, isTrue);
  });

  test('a later owner retries the failed prior pause before playing',
      () async {
    final arbiter = VideoPlaybackArbiter();
    var pauses = 0;
    arbiter.reserve(Object(), () async {
      if (pauses++ == 0) throw StateError('pause failed');
    });
    final failed = arbiter.reserve(Object(), () async {});
    await expectLater(failed.waitUntilReady(), throwsStateError);
    failed.release();

    final retry = arbiter.reserve(Object(), () async {});
    await retry.waitUntilReady();
    expect(pauses, 2);
    expect(retry.isCurrent, isTrue);
  });

  test('cancelled pending owner preserves a held failed pause for retry',
      () async {
    final arbiter = VideoPlaybackArbiter();
    final releaseFirstPause = Completer<void>();
    var pauses = 0;
    arbiter.reserve(Object(), () async {
      pauses++;
      if (pauses == 1) await releaseFirstPause.future;
    });
    final pending = arbiter.reserve(Object(), () async {});
    pending.release();
    final blocked = arbiter.reserve(Object(), () async {});
    releaseFirstPause.completeError(StateError('pause failed'));
    await expectLater(blocked.waitUntilReady(), throwsStateError);
    blocked.release();

    final retry = arbiter.reserve(Object(), () async {});
    await retry.waitUntilReady();
    expect(pauses, 2);
    expect(retry.isCurrent, isTrue);
  });

  test('same owner reentry replaces its token without pausing itself',
      () async {
    final arbiter = VideoPlaybackArbiter();
    final owner = Object();
    var pauses = 0;
    final first = arbiter.reserve(owner, () async => pauses++);
    final next = arbiter.reserve(owner, () async => pauses++);
    await next.waitUntilReady();

    expect(first.isCurrent, isFalse);
    expect(next.isCurrent, isTrue);
    expect(pauses, 0);
  });

  test('settled pause barriers are not retained for later activations',
      () async {
    final arbiter = VideoPlaybackArbiter();
    final first = arbiter.reserve(Object(), () async {});
    final second = arbiter.reserve(Object(), () async {});
    await second.waitUntilReady();
    await Future<void>.delayed(Duration.zero);

    expect(first.isCurrent, isFalse);
    expect(arbiter.debugPendingBarrierCount, 0);
    expect(second.debugRetainedPriorStateCount, 0);
    second.release();
    expect(second.debugRetainedPriorStateCount, 0);
  });
}
