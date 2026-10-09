import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/timeline_scroll_anchor.dart';

class _Window {
  final scroll = ScrollController();
  final viewport = GlobalKey();
  final keys = <String, GlobalKey>{};
  int start = 300;
  double leadingPadding = 0;
  late StateSetter update;

  Widget build() => Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 360,
            height: 500,
            child: StatefulBuilder(builder: (_, setState) {
              update = setState;
              final ids = List.generate(200, (i) => '${start + 199 - i}');
              return SizedBox(
                key: viewport,
                child: AnchoredTimelineList(
                  controller: scroll,
                  eventIds: ids,
                  messageKeys: keys,
                  followLatest: false,
                  padding: EdgeInsets.only(bottom: leadingPadding),
                  itemBuilder: (_, i) => SizedBox(
                    key: ValueKey(ids[i]),
                    child: SizedBox(
                      key: keys.putIfAbsent(ids[i], GlobalKey.new),
                      height: 100,
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      );

  Future<void> openAtHistoryEdge(WidgetTester tester) async {
    await tester.pumpWidget(build());
    scroll.jumpTo(18550);
    await tester.pump();
    update(() => start = 200);
    await tester.pump();
    scroll.jumpTo(9840);
    await tester.pump();
  }

  double anchorY(String id) =>
      (keys[id]!.currentContext!.findRenderObject()! as RenderBox)
          .localToGlobal(Offset.zero)
          .dy;

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  }
}

void main() {
  testWidgets('equal-extent history rebase keeps ballistic ticks continuous',
      (tester) async {
    final window = _Window();
    await window.openAtHistoryEdge(tester);
    await tester.fling(find.byKey(window.viewport), const Offset(0, 180), 2500);
    await tester.pump(const Duration(milliseconds: 16));
    final position = window.scroll.position;
    final anchor = TimelineScrollAnchor.capture(window.keys, window.viewport)!;
    final before = window.anchorY(anchor.eventId);
    final minimum = position.minScrollExtent;
    final maximum = position.maxScrollExtent;
    expect(position.extentAfter,
        lessThanOrEqualTo(position.viewportDimension * 2));
    expect(position.activity, isA<BallisticScrollActivity>());

    window.update(() => window.start = 100);
    await tester.pump();
    expect(position.minScrollExtent, minimum);
    expect(position.maxScrollExtent, maximum);
    expect(window.anchorY(anchor.eventId), closeTo(before, 1));

    var previous = before;
    for (var tick = 0; tick < 3; tick++) {
      await tester.pump(const Duration(milliseconds: 16));
      final box =
          window.keys[anchor.eventId]?.currentContext?.findRenderObject();
      expect(box, isA<RenderBox>(),
          reason:
              'a retained visible anchor must not disappear on the next tick');
      final y = window.anchorY(anchor.eventId);
      expect((y - previous).abs(), lessThan(100),
          reason:
              'simulation must start at rebased pixels, preserving velocity');
      expect(position.activity, isA<BallisticScrollActivity>());
      previous = y;
    }
    await window.close(tester);
  });

  testWidgets('history rebase preserves a held drag and its next movement',
      (tester) async {
    final window = _Window();
    await window.openAtHistoryEdge(tester);
    final gesture = await tester
        .startGesture(tester.getCenter(find.byKey(window.viewport)));
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();
    final anchor = TimelineScrollAnchor.capture(window.keys, window.viewport)!;
    final before = window.anchorY(anchor.eventId);
    expect(window.scroll.position.activity, isA<DragScrollActivity>());
    window.update(() => window.start = 100);
    await tester.pump();
    expect(window.anchorY(anchor.eventId), closeTo(before, 1));
    expect(window.scroll.position.activity, isA<DragScrollActivity>());
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(window.anchorY(anchor.eventId), closeTo(before + 40, 1));
    await gesture.up();
    await window.close(tester);
  });

  testWidgets('newer window rebase keeps reverse ballistic motion continuous',
      (tester) async {
    final window = _Window();
    await window.openAtHistoryEdge(tester);
    final position = window.scroll.position;
    window.scroll.jumpTo(position.minScrollExtent + 1100);
    await tester.pump();
    await tester.fling(
        find.byKey(window.viewport), const Offset(0, -180), 2500);
    await tester.pump(const Duration(milliseconds: 16));
    final anchor = TimelineScrollAnchor.capture(window.keys, window.viewport)!;
    final before = window.anchorY(anchor.eventId);
    final minimum = position.minScrollExtent;
    final maximum = position.maxScrollExtent;
    expect(position.extentBefore,
        lessThanOrEqualTo(position.viewportDimension * 2));
    expect(position.activity, isA<BallisticScrollActivity>());

    // The newer slice drops the old center, retains the visible overlap, and
    // changes the content extents. This controls Framework's normal restart.
    window.update(() => window.start = 350);
    await tester.pump();
    expect(
        position.minScrollExtent == minimum &&
            position.maxScrollExtent == maximum,
        isFalse);
    expect(window.anchorY(anchor.eventId), closeTo(before, 1));
    var previous = before;
    for (var tick = 0; tick < 3; tick++) {
      await tester.pump(const Duration(milliseconds: 16));
      final y = window.anchorY(anchor.eventId);
      expect(y, lessThan(previous));
      expect(previous - y, lessThan(100));
      expect(position.activity, isA<BallisticScrollActivity>());
      previous = y;
    }
    await window.close(tester);
  });

  testWidgets('leading padding correction retains ballistic speed and anchor',
      (tester) async {
    final window = _Window();
    await tester.pumpWidget(window.build());
    window.scroll.jumpTo(900);
    await tester.pump();
    await tester.fling(find.byKey(window.viewport), const Offset(0, 180), 2500);
    await tester.pump(const Duration(milliseconds: 16));
    final anchor = TimelineScrollAnchor.capture(window.keys, window.viewport)!;
    final before = window.anchorY(anchor.eventId);
    expect(window.scroll.position.activity, isA<BallisticScrollActivity>());
    window.update(() => window.leadingPadding = 80);
    await tester.pump();
    expect(window.anchorY(anchor.eventId), closeTo(before, 1));
    var previous = before;
    for (var tick = 0; tick < 3; tick++) {
      await tester.pump(const Duration(milliseconds: 16));
      final y = window.anchorY(anchor.eventId);
      expect(y, greaterThan(previous));
      expect(y - previous, lessThan(100));
      expect(window.scroll.position.activity, isA<BallisticScrollActivity>());
      previous = y;
    }
    await window.close(tester);
  });
}
