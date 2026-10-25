import 'package:liuhetong_mobile/ui/chat/latest_message_anchor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/timeline_scroll_anchor.dart';

void main() {
  for (final mode in ['latest', 'history', 'drag', 'ballistic']) {
    testWidgets('viewport height changes preserve reading position, mode=$mode',
        (tester) async {
      final reading = mode != 'latest';
      final scroll = ScrollController();
      final keys = <String, GlobalKey>{};
      final viewport = GlobalKey();
      final ids = List.generate(30, (i) => '${29 - i}');
      var height = 500.0;
      var previousOffset = 0.0;
      var readerMovement = 0.0;
      scroll.addListener(() {
        readerMovement += scroll.position.pixels - previousOffset;
        previousOffset = scroll.position.pixels;
      });
      late StateSetter update;
      await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
              alignment: Alignment.topCenter,
              child: StatefulBuilder(builder: (_, setState) {
                update = setState;
                return SizedBox(
                    key: viewport,
                    width: 360,
                    height: height,
                    child: AnchoredTimelineList(
                        controller: scroll,
                        eventIds: ids,
                        messageKeys: keys,
                        onOriginRebased: (delta) => previousOffset += delta,
                        itemBuilder: (_, i) => SizedBox(
                            key: ValueKey(ids[i]),
                            child: SizedBox(
                                key: keys.putIfAbsent(ids[i], GlobalKey.new),
                                height: 65,
                                child: Text(ids[i])))));
              }))));
      if (reading) scroll.jumpTo(600);
      await tester.pump();
      update(() {});
      await tester.pump();
      TestGesture? gesture;
      if (mode == 'drag') {
        gesture =
            await tester.startGesture(tester.getCenter(find.byKey(viewport)));
        await gesture.moveBy(const Offset(0, 70));
        await tester.pump();
        expect(scroll.position.activity, isA<DragScrollActivity>());
      } else if (mode == 'ballistic') {
        await tester.fling(find.byKey(viewport), const Offset(0, 100), 1800);
        await tester.pump(const Duration(milliseconds: 16));
        expect(scroll.position.activity, isA<BallisticScrollActivity>());
      }
      // Keep the reading row inside even the smallest tested viewport. A row
      // at the old bottom can legitimately leave the lazy list when it shrinks.
      final anchorId = ids.firstWhere((id) {
        final box = keys[id]?.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.attached || !box.hasSize) return false;
        final y = box.localToGlobal(Offset.zero).dy -
            tester.getTopLeft(find.byKey(viewport)).dy;
        return y >= 100 && y <= 200;
      });
      final before = tester.getTopLeft(find.byKey(keys[anchorId]!)).dy -
          tester.getTopLeft(find.byKey(viewport)).dy;
      previousOffset = scroll.position.pixels;
      readerMovement = 0;
      for (final next in [471.0, 500.0, 350.0, 500.0]) {
        update(() => height = next);
        await tester.pump();
        if (reading) {
          expect(
              tester.getTopLeft(find.byKey(keys[anchorId]!)).dy -
                  tester.getTopLeft(find.byKey(viewport)).dy,
              closeTo(before, 1));
          expect(scroll.position.pixels - previousOffset, closeTo(0, .01),
              reason: 'owner coordinates include layout corrections');
          expect(readerMovement, closeTo(0, .01),
              reason: 'layout corrections are not reader movement');
        } else {
          expect(scroll.position.extentBefore, lessThan(.5));
        }
      }
      if (gesture != null) {
        expect(scroll.position.activity, isA<DragScrollActivity>());
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump();
        expect(readerMovement, closeTo(-30, 1),
            reason: 'next movement toward latest keeps its direction');
        await gesture.up();
      } else if (mode == 'ballistic') {
        await tester.pump(const Duration(milliseconds: 16));
        expect(scroll.position.activity, isA<BallisticScrollActivity>());
        expect(readerMovement, greaterThan(0));
        expect(readerMovement, lessThan(100));
      } else if (reading) {
        scroll.jumpTo(scroll.position.pixels - 5);
        expect(readerMovement, closeTo(-5, .01));
      }
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    });
  }

  testWidgets('send follows layout-only media refinement until navigation',
      (tester) async {
    final scroll = ScrollController();
    final anchor = LatestMessageAnchor(scroll);
    final height = ValueNotifier<double>(90);
    final keys = <String, GlobalKey>{};
    final ids = List.generate(20, (i) => '${19 - i}');
    late StateSetter update;
    var builds = 0;
    await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
            child: SizedBox(
                width: 360,
                height: 500,
                child: StatefulBuilder(builder: (_, setState) {
                  update = setState;
                  builds++;
                  return AnchoredTimelineList(
                      controller: scroll,
                      eventIds: ids,
                      messageKeys: keys,
                      latestFollowRequested: () => anchor.followingLatest,
                      itemBuilder: (_, i) => SizedBox(
                          key: ValueKey(ids[i]),
                          child: ValueListenableBuilder<double>(
                              valueListenable: height,
                              builder: (_, value, child) => SizedBox(
                                  key: keys.putIfAbsent(ids[i], GlobalKey.new),
                                  height: i == 0 ? value : 65,
                                  child: Text(ids[i])))));
                })))));
    scroll.jumpTo(120);
    await tester.pump();
    update(() {}); // Establish a visible history origin.
    await tester.pump();
    anchor.update('send', outgoing: true, newSend: true);
    await tester.pumpAndSettle();
    expect(scroll.position.extentBefore, lessThan(.5));
    final beforeBuilds = builds;
    height.value = 310;
    await tester.pumpAndSettle();
    expect(builds, beforeBuilds,
        reason: 'media relayout does not rebuild timeline');
    expect(scroll.position.extentBefore, lessThan(.5));
    scroll.jumpTo(scroll.position.minScrollExtent + 120);
    expect(anchor.followingLatest, isFalse);
    await tester.pump();
    expect(scroll.position.extentBefore, greaterThan(100));
    anchor.dispose();
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
    height.dispose();
  });

  testWidgets(
      'history anchor survives newer bubble geometry changing with same IDs',
      (tester) async {
    final scroll = ScrollController();
    final keys = <String, GlobalKey>{};
    var newestHeight = 90.0;
    late StateSetter update;
    final ids = List.generate(20, (i) => '${19 - i}');
    await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
            child: SizedBox(
                width: 360,
                height: 500,
                child: StatefulBuilder(builder: (_, setState) {
                  update = setState;
                  return AnchoredTimelineList(
                      controller: scroll,
                      eventIds: ids,
                      messageKeys: keys,
                      itemBuilder: (_, i) => SizedBox(
                          key: ValueKey(ids[i]),
                          child: SizedBox(
                              key: keys.putIfAbsent(ids[i], GlobalKey.new),
                              height: i == 0 ? newestHeight : 65,
                              child: Text(ids[i]))));
                })))));
    scroll.jumpTo(120);
    await tester.pump();
    final before = tester.getTopLeft(find.byKey(keys['17']!)).dy;
    update(() => newestHeight = 310);
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(keys['17']!)).dy, closeTo(before, 1));
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });

  for (final readingHistory in [false, true]) {
    testWidgets(
        'cached image head hydration retains latest or reader: $readingHistory',
        (tester) async {
      final scroll = ScrollController();
      final keys = <String, GlobalKey>{};
      var newest = 7;
      var imageHeight = 90.0;
      late StateSetter update;
      await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
              child: SizedBox(
                  width: 360,
                  height: 500,
                  child: StatefulBuilder(builder: (_, setState) {
                    update = setState;
                    final ids =
                        List.generate(newest + 1, (i) => '${newest - i}');
                    return AnchoredTimelineList(
                        controller: scroll,
                        eventIds: ids,
                        messageKeys: keys,
                        itemBuilder: (_, i) => SizedBox(
                            key: ValueKey(ids[i]),
                            child: SizedBox(
                                key: keys.putIfAbsent(ids[i], GlobalKey.new),
                                height: int.parse(ids[i]) % 3 == 0
                                    ? imageHeight
                                    : 65,
                                child: Text('synthetic ${ids[i]}'))));
                  })))));
      if (readingHistory) {
        scroll.jumpTo(60);
        await tester.pump();
      }
      final before = tester.getTopLeft(find.byKey(keys['5']!)).dy;
      update(() => newest = 39);
      await tester.pumpAndSettle();
      if (readingHistory) {
        expect(
            tester.getTopLeft(find.byKey(keys['5']!)).dy, closeTo(before, 1));
      } else {
        expect(scroll.position.extentBefore, lessThan(.5),
            reason: 'canonical head must reach newest cached bubble');
        update(() => imageHeight = 310);
        await tester.pumpAndSettle();
        expect(scroll.position.extentBefore, lessThan(.5),
            reason: 'image decode must retain newest edge');
      }
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    });
  }
}
