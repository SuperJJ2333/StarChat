import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/startup_projection/startup_projection_coordinator.dart';

void main() {
  test('concurrent mutations share confirmed invalidation, retain revisions',
      () async {
    var calls = 0;
    final barrier = Completer<void>();
    final owner = StartupProjectionCoordinator(invalidateHead: () async {
      calls++;
      await barrier.future;
    })
      ..markVerified();
    final old = owner.beginCapture()!;
    final a = owner.beginMutation('echo');
    final b = owner.beginMutation('ack');
    expect(owner.isCurrent(old), isFalse);
    expect(owner.beginCapture(), isNull);
    barrier.complete();
    await Future.wait([a.beforeApply, b.beforeApply]);
    expect(calls, 1);
    a.finish(applied: true);
    expect(owner.beginCapture(), isNull);
    b.finish(applied: true);
    expect(owner.beginCapture()!.revision, greaterThan(old.revision));
  });

  test('failed invalidation is never reused', () async {
    var calls = 0;
    final owner = StartupProjectionCoordinator(invalidateHead: () async {
      if (++calls == 1) throw StateError('synthetic invalidation');
    });
    final a = owner.beginMutation('one');
    await expectLater(a.beforeApply, throwsStateError);
    a.finish(applied: false);
    final b = owner.beginMutation('two');
    await b.beforeApply;
    b.finish(applied: true);
    expect(calls, 2);
    expect(owner.canCapture, isFalse);
  });

  test('partial head write failure forces next mutation to invalidate',
      () async {
    var calls = 0;
    var head = false;
    final owner = StartupProjectionCoordinator(invalidateHead: () async {
      calls++;
      head = false;
    })
      ..markVerified();
    await owner.runMutation('one', () async {});
    await expectLater(
        owner.commit(owner.beginCapture()!, () async {
          head = true;
          throw StateError('synthetic partial write');
        }),
        throwsStateError);
    await owner.runMutation('two', () async {
      expect(head, isFalse);
    });
    expect(calls, 2);
  });

  test('mutation during head write cannot leave stale head alive', () async {
    var head = false;
    final writing = Completer<void>();
    final release = Completer<void>();
    final owner = StartupProjectionCoordinator(invalidateHead: () async {
      head = false;
    })
      ..markVerified();
    final result = owner.commit(owner.beginCapture()!, () async {
      writing.complete();
      await release.future;
      head = true;
    });
    await writing.future;
    final mutation = owner.beginMutation('racing');
    release.complete();
    expect(await result, isFalse);
    await mutation.beforeApply;
    expect(head, isFalse);
    mutation.finish(applied: true);
  });
}
