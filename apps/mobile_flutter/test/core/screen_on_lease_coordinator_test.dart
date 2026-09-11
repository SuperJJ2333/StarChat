import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/screen_on_lease_coordinator.dart';

void main() {
  test('releasing one owner keeps the screen on for another owner', () async {
    final calls = <bool>[];
    final coordinator = ScreenOnLeaseCoordinator((enabled) async {
      calls.add(enabled);
    });

    final call = coordinator.acquire();
    final video = coordinator.acquire();
    call.release();
    await coordinator.settled;

    expect(calls, isNot(contains(false)));
    video.release();
    await coordinator.settled;
    expect(calls.last, isFalse);
  });

  test('late duplicate release cannot disable a newer owner', () async {
    final calls = <bool>[];
    final coordinator = ScreenOnLeaseCoordinator((enabled) async {
      calls.add(enabled);
    });
    final oldOwner = coordinator.acquire();
    oldOwner.release();
    final newOwner = coordinator.acquire();
    oldOwner.release();
    await coordinator.settled;

    expect(calls, isNot(contains(false)));
    newOwner.release();
    await coordinator.settled;
    expect(calls.last, isFalse);
  });

  test('held platform toggle drains the final state serially', () async {
    final calls = <bool>[];
    final started = Completer<void>();
    final releaseToggle = Completer<void>();
    var active = 0;
    var peakActive = 0;
    final coordinator = ScreenOnLeaseCoordinator((enabled) async {
      active++;
      peakActive = peakActive > active ? peakActive : active;
      calls.add(enabled);
      if (calls.length == 1) {
        started.complete();
        await releaseToggle.future;
      }
      active--;
    });
    final owner = coordinator.acquire();
    await started.future;
    owner.release();
    releaseToggle.complete();
    await coordinator.settled;

    expect(calls, [true, false]);
    expect(peakActive, 1);
  });

  test('platform failure does not strand a later owner state', () async {
    final calls = <bool>[];
    var count = 0;
    final coordinator = ScreenOnLeaseCoordinator((enabled) async {
      calls.add(enabled);
      if (count++ == 0) throw StateError('platform failure');
    });
    final failedOwner = coordinator.acquire();
    await coordinator.settled;
    failedOwner.release();
    final laterOwner = coordinator.acquire();
    await coordinator.settled;

    expect(calls.last, isTrue);
    laterOwner.release();
    await coordinator.settled;
    expect(calls.last, isFalse);
  });
}
