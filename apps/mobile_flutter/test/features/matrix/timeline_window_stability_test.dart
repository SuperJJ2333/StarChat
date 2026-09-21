import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/timeline_scroll_anchor.dart';

void main() {
  for (final tallRow in [false, true]) {
    for (final cancelAfterFirstFrame in [false, true]) {
      testWidgets(
          'every painted frame preserves overlapping rows, drag=$cancelAfterFirstFrame tall=$tallRow',
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
                          child: AnchoredTimelineList(
                              controller: scroll,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              messageKeys: keys,
                              eventIds: items,
                              itemBuilder: (_, index) => SizedBox(
                                  key: ValueKey(items[index]),
                                  child: SizedBox(
                                      key: keys.putIfAbsent(
                                          items[index], GlobalKey.new),
                                      height: tallRow && items[index] == '366'
                                          ? 5000
                                          : [
                                              44.0,
                                              120.0,
                                              240.0,
                                              64.0
                                            ][int.parse(items[index]) % 4]))));
                    })))));
        scroll.jumpTo(tallRow ? 20760 : 16000);
        await tester.pump();
        final anchor = TimelineScrollAnchor.capture(keys, viewportKey)!;
        expect(int.parse(anchor.eventId), lessThan(400));
        final gesture = cancelAfterFirstFrame
            ? await tester
                .startGesture(tester.getCenter(find.byKey(viewportKey)))
            : null;
        var collecting = true;
        var frame = 0;
        final samples = <Map<String, Object?>>[];
        WidgetsBinding.instance.addPersistentFrameCallback((_) {
          if (!collecting) return;
          final ro = keys[anchor.eventId]?.currentContext?.findRenderObject();
          final y = ro is RenderBox && ro.attached && ro.hasSize
              ? ro.localToGlobal(Offset.zero).dy
              : null;
          samples.add({
            'frame': frame++,
            'anchor': anchor.eventId,
            'expectedY': anchor.globalY,
            'actualY': y,
            'errorY': y == null ? null : y - anchor.globalY,
            'offset': scroll.offset,
            'fingerDown': gesture != null
          });
        });
        update(() => start = 200);
        // No post-paint restoration operation exists to be cancelled. A subsequent
        // gesture or generation change cannot leave the coordinate change halfway.
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        collecting = false;
        debugPrint(
            'FRAME_AUDIT ${cancelAfterFirstFrame ? "drag" : "idle"}: $samples');

        for (final sample in samples) {
          expect(sample['actualY'], isNotNull);
          expect((sample['errorY'] as double).abs(), lessThan(1));
        }
        expect(find.byType(SizedBox).evaluate().length, lessThan(100),
            reason:
                'the transition must remain lazy, not mount the 200-row window');
        if (!cancelAfterFirstFrame) {
          final rect = tester.getRect(find.byKey(keys[anchor.eventId]!));
          expect(rect.top, closeTo(anchor.globalY, 1));
        }
        // Reverse the window replacement while the original row remains visible.
        samples.clear();
        collecting = true;
        update(() => start = 300);
        await tester.pump(const Duration(milliseconds: 16));
        collecting = false;
        for (final sample in samples) {
          expect(sample['actualY'], isNotNull);
          expect((sample['errorY'] as double).abs(), lessThan(1));
        }
        if (gesture != null) {
          final beforeDrag =
              tester.getRect(find.byKey(keys[anchor.eventId]!)).top;
          await gesture.moveBy(const Offset(0, 90));
          await tester.pump(const Duration(milliseconds: 16));
          expect(scroll.position.isScrollingNotifier.value, isTrue);
          final afterDrag =
              tester.getRect(find.byKey(keys[anchor.eventId]!)).top;
          expect(afterDrag, greaterThan(beforeDrag + 20));
          await tester.pump(const Duration(milliseconds: 150));
          expect(tester.getRect(find.byKey(keys[anchor.eventId]!)).top,
              closeTo(afterDrag, 1));
          await gesture.up();
        } else {
          // The retained row can become the newest row of the replacement.
          // Its leading padding is then part of the center origin.
          samples.clear();
          collecting = true;
          update(() => start = int.parse(anchor.eventId) - 199);
          await tester.pump(const Duration(milliseconds: 16));
          collecting = false;
          debugPrint('FRAME_AUDIT edge: $samples');
          for (final sample in samples) {
            expect(sample['actualY'], isNotNull);
            expect((sample['errorY'] as double).abs(), lessThan(1));
          }
          scroll.jumpTo(scroll.position.minScrollExtent);
          await tester.pump();
          update(() => start++);
          await tester.pump();
          expect(scroll.position.extentBefore, closeTo(0, 1),
              reason: 'incoming rows follow the latest edge when idle there');
        }
        await tester.pumpWidget(const SizedBox());
        scroll.dispose();
      });
    }
  }
}
