import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_home_snapshot_refresh_coordinator.dart';

void main() {
  testWidgets('a short window coalesces separate event-loop notifications',
      (tester) async {
    final coordinator = SnapshotRefreshCoordinator<int>(
        coalesceWindow: const Duration(milliseconds: 32));
    var loads = 0;
    final values = <int>[];
    final a = coordinator.request(() async => ++loads, onValue: values.add);
    await tester.pump(const Duration(milliseconds: 8));
    final b = coordinator.request(() async => ++loads, onValue: values.add);
    await tester.pump(const Duration(milliseconds: 24));
    await Future.wait([a, b]);
    expect(loads, 1);
    expect(values, [1]);
    coordinator.dispose();
  });

  testWidgets('navigation pause defers loading and keeps only latest request',
      (tester) async {
    final coordinator = SnapshotRefreshCoordinator<int>();
    coordinator.setPaused(true);
    var loads = 0;
    final values = <int>[];
    final a = coordinator.request(() async {
      loads++;
      return 1;
    }, onValue: values.add);
    await tester.pump();
    final b = coordinator.request(() async {
      loads++;
      return 2;
    }, onValue: values.add);
    await tester.pump(const Duration(milliseconds: 400));
    expect(loads, 0);
    coordinator.setPaused(false);
    await tester.pump();
    await Future.wait([a, b]);
    expect(loads, 1);
    expect(values, [2]);
    coordinator.dispose();
  });

  testWidgets('load finishing during navigation cannot publish stale result',
      (tester) async {
    final coordinator = SnapshotRefreshCoordinator<int>();
    final first = Completer<int>();
    final values = <int>[];
    final a = coordinator.request(() => first.future, onValue: values.add);
    await tester.pump();
    coordinator.setPaused(true);
    first.complete(1);
    await tester.pump();
    expect(values, isEmpty);
    final b = coordinator.request(() async => 2, onValue: values.add);
    coordinator.setPaused(false);
    await tester.pump();
    await Future.wait([a, b]);
    expect(values, [2]);
    coordinator.dispose();
  });

  testWidgets('disposal settles paused requests without a late publication',
      (tester) async {
    final coordinator = SnapshotRefreshCoordinator<int>();
    coordinator.setPaused(true);
    var published = false;
    final pending =
        coordinator.request(() async => 1, onValue: (_) => published = true);
    coordinator.dispose();
    await tester.pump();
    await pending;
    coordinator.setPaused(false);
    await tester.pump();
    expect(published, isFalse);
  });
}
