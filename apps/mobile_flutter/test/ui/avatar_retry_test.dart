import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/foundation/avatar_retry.dart';

void main() {
  testWidgets('shared queue spaces due retries and cancels disposed owners',
      (tester) async {
    final owners = List.generate(12, (_) => AvatarRetry());
    final called = <int>[];
    for (var i = 0; i < owners.length; i++) {
      owners[i].schedule(() => called.add(i));
    }
    await tester.pump(const Duration(seconds: 1));
    expect(called, [0]);
    await tester.pump(const Duration(seconds: 1));
    expect(called, [0, 1, 2, 3, 4]);
    for (final owner in owners) {
      owner.reset();
    }
    await tester.pump(const Duration(seconds: 120));
    expect(called, hasLength(5));
  });
  testWidgets('hidden owner and background queue do no retry work',
      (tester) async {
    final owner = AvatarRetry();
    var calls = 0;
    owner.setActive(false);
    owner.schedule(() => calls++);
    await tester.pump(const Duration(seconds: 120));
    expect(calls, 0);
    owner.setActive(true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 120));
    expect(calls, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 1);
    owner.reset();
  });
  testWidgets('long outage backs off to at most one retry per minute per owner',
      (tester) async {
    final owner = AvatarRetry();
    var calls = 0;
    void failed() {
      calls++;
      owner.schedule(failed);
    }

    owner.schedule(failed);
    for (var i = 0; i < 5; i++) {
      await tester.pump(Duration(seconds: [1, 2, 5, 15, 30][i]));
    }
    expect(calls, 5);
    await tester.pump(const Duration(seconds: 59));
    expect(calls, 5);
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 6);
    owner.reset();
  });
}
