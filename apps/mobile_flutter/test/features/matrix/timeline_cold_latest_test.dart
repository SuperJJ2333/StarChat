import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/timeline_scroll_anchor.dart';

void main() {
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
