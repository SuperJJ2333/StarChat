import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/video_playback_lease_coordinator.dart';

void main() {
  late VideoPlaybackLeaseCoordinator crossZoneCoordinator;
  late List<bool> crossZoneCalls;

  setUpAll(() {
    crossZoneCalls = <bool>[];
    crossZoneCoordinator = VideoPlaybackLeaseCoordinator((enabled) async {
      crossZoneCalls.add(enabled);
    });
  });

  testWidgets('first FakeAsync cycle drains without retaining its future',
      (tester) async {
    final token = crossZoneCoordinator.acquire();
    crossZoneCoordinator.revoke(token);
    await tester.pump();
    await crossZoneCoordinator.settled;
    expect(crossZoneCalls.last, isFalse);
  });

  testWidgets('next FakeAsync cycle can acquire after prior drain',
      (tester) async {
    final token = crossZoneCoordinator.acquire();
    await tester.pump();
    await crossZoneCoordinator.settled;
    expect(crossZoneCoordinator.current, token);
    expect(crossZoneCalls.last, isTrue);
    crossZoneCoordinator.revoke(token);
    await tester.pump();
    await crossZoneCoordinator.settled;
  });

  test('late old owner release cannot disable newer owner', () async {
    final enabled = <bool>[];
    final firstEnable = Completer<void>();
    final started = Completer<void>();
    var calls = 0;
    final coordinator = VideoPlaybackLeaseCoordinator((value) {
      enabled.add(value);
      if (++calls == 1) {
        started.complete();
        return firstEnable.future;
      }
      return Future.value();
    });
    final a = coordinator.acquire();
    await started.future;
    final b = coordinator.acquire();
    coordinator.revoke(a);
    firstEnable.complete();
    await Future<void>.delayed(Duration.zero);
    expect(coordinator.current, b);
    expect(enabled.last, isTrue);
    expect(enabled, isNot(contains(false)));
  });

  test('failed wakelock operation does not block a later owner', () async {
    var calls = 0;
    final values = <bool>[];
    final failed = Completer<void>();
    final coordinator = VideoPlaybackLeaseCoordinator((enabled) async {
      values.add(enabled);
      if (++calls == 1) {
        failed.complete();
        throw StateError('platform failure');
      }
    });
    coordinator.acquire();
    await failed.future;
    final next = coordinator.acquire();
    await coordinator.settled;
    expect(coordinator.current, next);
    expect(calls, greaterThanOrEqualTo(2));
    expect(values.last, isTrue);
  });

  test('rapid background foreground and final release serialize transitions',
      () async {
    final calls = <bool>[];
    var active = 0;
    var peakActive = 0;
    final heldDisable = Completer<void>();
    final coordinator = VideoPlaybackLeaseCoordinator((enabled) async {
      active++;
      peakActive = peakActive > active ? peakActive : active;
      calls.add(enabled);
      if (!enabled && !heldDisable.isCompleted) await heldDisable.future;
      active--;
    });
    final first = coordinator.acquire();
    coordinator.revoke(first);
    await Future<void>.delayed(Duration.zero);
    final second = coordinator.acquire();
    heldDisable.complete();
    await Future<void>.delayed(Duration.zero);
    expect(calls.last, isTrue);
    expect(coordinator.current, second);
    coordinator.revoke(second);
    await coordinator.dispose();
    expect(calls.last, isFalse);
    expect(peakActive, 1);
    expect(coordinator.current, isNull);
    expect(() => coordinator.acquire(), throwsStateError);
  });
}
