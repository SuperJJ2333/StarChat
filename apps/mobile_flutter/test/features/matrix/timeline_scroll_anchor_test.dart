import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/timeline_scroll_anchor.dart';

void main() {
  testWidgets(
      'overlapping reverse window restores actual variable-height row pixels',
      (tester) async {
    final scroll = ScrollController();
    final viewportKey = GlobalKey();
    final keys = <String, GlobalKey>{};
    var start = 300;
    late StateSetter update;
    List<String> ids() => List.generate(200, (i) => '${start + 199 - i}');
    await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
            child: SizedBox(
                width: 360,
                height: 500,
                child: StatefulBuilder(builder: (_, setState) {
                  update = setState;
                  final items = ids();
                  return SizedBox(
                      key: viewportKey,
                      child: ListView.builder(
                          controller: scroll,
                          reverse: true,
                          itemCount: items.length,
                          findChildIndexCallback: (key) =>
                              key is ValueKey<String>
                                  ? items.indexOf(key.value)
                                  : null,
                          itemBuilder: (_, index) => SizedBox(
                              key: ValueKey(items[index]),
                              child: SizedBox(
                                  key: keys.putIfAbsent(
                                      items[index], GlobalKey.new),
                                  height: [
                                    44.0,
                                    120.0,
                                    240.0,
                                    64.0
                                  ][int.parse(items[index]) % 4]))));
                })))));
    scroll.jumpTo(16000);
    await tester.pump();
    final anchor = TimelineScrollAnchor.capture(keys, viewportKey)!;
    expect(int.parse(anchor.eventId), lessThan(400));
    update(() => start = 200);
    var done = false;
    final operation = anchor
        .restore(
            controller: scroll,
            keys: keys,
            eventIds: ids(),
            isMounted: () => true)
        .then((_) => done = true);
    for (var i = 0; i < 120 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await operation;
    final rect = tester.getRect(find.byKey(keys[anchor.eventId]!));
    expect(rect.top, closeTo(anchor.globalY, 1));
    final returnAnchor = TimelineScrollAnchor.capture(keys, viewportKey)!;
    update(() => start = 300);
    done = false;
    final returning = returnAnchor
        .restore(
            controller: scroll,
            keys: keys,
            eventIds: ids(),
            isMounted: () => true)
        .then((_) => done = true);
    for (var i = 0; i < 120 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await returning;
    expect(tester.getRect(find.byKey(keys[returnAnchor.eventId]!)).top,
        closeTo(returnAnchor.globalY, 1));
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });
}
