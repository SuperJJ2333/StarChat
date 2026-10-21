import 'package:liuhetong_mobile/ui/chat/latest_message_anchor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/timeline_scroll_anchor.dart';

void main() {
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
