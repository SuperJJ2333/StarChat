import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_viewport.dart';
import 'package:liuhetong_mobile/features/matrix/timeline_scroll_anchor.dart';

void main() {
  testWidgets('twelve consecutive fast flings retain rows on each older page',
      (tester) async {
    final window = RoomTimelineViewport<int>(
      idOf: (id) => '$id',
      project: (id) => RoomMessageViewModel(
        id: '$id',
        senderId: 'synthetic',
        text: 'fixture',
        isOwn: false,
        deliveryState: RoomDeliveryState.sent,
        timestamp: DateTime.utc(2026).add(Duration(hours: id)),
      ),
    )..update(List.generate(10000, (i) => i));
    window.anchor('9000');
    final scroll = ScrollController();
    final viewport = GlobalKey();
    final keys = <String, GlobalKey>{};
    late StateSetter update;
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
          child: SizedBox(
        width: 360,
        height: 500,
        child: StatefulBuilder(builder: (_, setState) {
          update = setState;
          final ids = window.snapshot().reversed.map((m) => m.id).toList();
          return SizedBox(
              key: viewport,
              child: AnchoredTimelineList(
                controller: scroll,
                eventIds: ids,
                messageKeys: keys,
                followLatest: false,
                itemBuilder: (_, i) => SizedBox(
                    key: ValueKey(ids[i]),
                    child: SizedBox(
                        key: keys.putIfAbsent(ids[i], GlobalKey.new),
                        height: int.parse(ids[i]) % 300 == 0
                            ? 5000
                            : [
                                44.0,
                                120.0,
                                240.0,
                                64.0
                              ][int.parse(ids[i]) % 4])),
              ));
        }),
      )),
    ));
    final initialOldest = int.parse(window.snapshot().first.id);
    var shifts = 0;
    for (var burst = 0; burst < 12; burst++) {
      await tester.fling(find.byKey(viewport), const Offset(0, 350), 10000);
      await tester.pumpAndSettle();
      if (scroll.position.extentAfter > 1000) continue;
      final ids = window.snapshot().reversed.map((m) => m.id).toList();
      final retained = TimelineScrollAnchor.visibleBoundaryEventId(
          keys, viewport, ids,
          earlier: true)!;
      final before = tester.getTopLeft(find.byKey(keys[retained]!)).dy;
      update(() => window.earlier(retainEventId: retained));
      shifts++;
      await tester.pump();
      expect(
          tester.getTopLeft(find.byKey(keys[retained]!)).dy, closeTo(before, 1),
          reason: 'burst $burst must not jump days');
      expect(window.retainedModels, lessThanOrEqualTo(200));
      expect(window.snapshot().map((m) => m.id).toSet().length,
          window.snapshot().length);
      expect(scroll.positions.length, 1);
      expect(tester.takeException(), isNull);
    }
    expect(shifts, greaterThanOrEqualTo(3));
    expect(int.parse(window.snapshot().first.id), lessThan(initialOldest - 200),
        reason: 'preserving visible rows must still advance history');
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });

  testWidgets('older edge shift retains visible tall row outside half overlap',
      (tester) async {
    final window = RoomTimelineViewport<int>(
      idOf: (id) => '$id',
      project: (id) => RoomMessageViewModel(
        id: '$id',
        senderId: 'synthetic',
        text: 'fixture',
        isOwn: false,
        deliveryState: RoomDeliveryState.sent,
        timestamp: DateTime.utc(2026).add(Duration(days: id)),
      ),
    )..update(List.generate(500, (i) => i));
    window.anchor('300');
    final scroll = ScrollController();
    final viewport = GlobalKey();
    final keys = <String, GlobalKey>{};
    late StateSetter update;
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
          child: SizedBox(
        width: 360,
        height: 500,
        child: StatefulBuilder(builder: (_, setState) {
          update = setState;
          final ids = window.snapshot().reversed.map((m) => m.id).toList();
          return SizedBox(
              key: viewport,
              child: AnchoredTimelineList(
                controller: scroll,
                eventIds: ids,
                messageKeys: keys,
                followLatest: false,
                itemBuilder: (_, i) => SizedBox(
                    key: ValueKey(ids[i]),
                    child: SizedBox(
                        key: keys.putIfAbsent(ids[i], GlobalKey.new),
                        height: ids[i] == '300'
                            ? 5000
                            : int.parse(ids[i]) > 300
                                ? 20
                                : 1)),
              ));
        }),
      )),
    ));
    scroll.jumpTo(6350);
    await tester.pump();
    await tester.fling(find.byKey(viewport), const Offset(0, 100), 2500);
    await tester.pump(const Duration(milliseconds: 16));
    final anchor = TimelineScrollAnchor.capture(keys, viewport)!;
    expect(anchor.eventId, '300');
    expect(scroll.position.extentAfter, lessThan(1000),
        reason: 'RoomPage admits older pagination at two viewport heights');
    final before = tester.getTopLeft(find.byKey(keys['300']!)).dy;
    final retained = TimelineScrollAnchor.visibleBoundaryEventId(
        keys, viewport, window.snapshot().reversed.map((m) => m.id),
        earlier: true);
    expect(retained, '300', reason: 'partial tall rows are visible too');
    update(() => window.earlier(retainEventId: retained));
    await tester.pump();
    expect(window.snapshot().map((m) => m.id), contains(anchor.eventId),
        reason: 'pixel proximity cannot justify dropping the visible row');
    expect(tester.getTopLeft(find.byKey(keys['300']!)).dy, closeTo(before, 1));
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });
}
