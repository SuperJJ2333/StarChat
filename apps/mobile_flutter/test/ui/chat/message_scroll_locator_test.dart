import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/timeline_scroll_anchor.dart';
import 'package:liuhetong_mobile/ui/chat/message_scroll_locator.dart';

void main() {
  testWidgets('reveals far lazy variable-height messages in both directions',
      (tester) async {
    final controller = ScrollController();
    final keys = <String, GlobalKey>{};
    final ids = List.generate(180, (i) => 'event-$i');
    final active = <int>{};
    var peakActive = 0;
    await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
            child: SizedBox(
          width: 360,
          height: 500,
          child: ListView.builder(
              controller: controller,
              reverse: true,
              itemCount: ids.length,
              itemBuilder: (_, i) => _TrackedMessage(
                    key: keys.putIfAbsent(ids[i], GlobalKey.new),
                    height: [44.0, 120.0, 280.0, 64.0, 180.0][i % 5],
                    onMount: () {
                      active.add(i);
                      if (active.length > peakActive) {
                        peakActive = active.length;
                      }
                    },
                    onUnmount: () => active.remove(i),
                  )),
        ))));
    for (final index in [157, 8, 179, 0]) {
      expect(keys[ids[index]]?.currentContext, isNull);
      bool? result;
      final operation = revealLazyMessage(
          controller: controller,
          eventIds: ids,
          messageKeys: keys,
          eventId: ids[index],
          isMounted: () => true).then((value) => result = value);
      for (var frame = 0; frame < 600 && result == null; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await operation;
      expect(result, isTrue, reason: 'target $index');
      final target = tester.getRect(find.byKey(keys[ids[index]]!));
      final viewport = tester.getRect(find.byType(ListView));
      expect(target.overlaps(viewport), isTrue);
      if (index != 0 && index != ids.length - 1) {
        expect(target.center.dy, closeTo(viewport.center.dy, 1));
      }
      expect(active.length, lessThan(25));
    }
    expect(peakActive, lessThan(30), reason: 'must retain lazy construction');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('missing target and detached view exit without scrolling',
      (tester) async {
    final controller = ScrollController();
    expect(
        await revealLazyMessage(
            controller: controller,
            eventIds: ['a'],
            messageKeys: {},
            eventId: 'missing',
            isMounted: () => true),
        isFalse);
    expect(
        await revealLazyMessage(
            controller: controller,
            eventIds: ['a'],
            messageKeys: {},
            eventId: 'a',
            isMounted: () => false),
        isFalse);
    controller.dispose();
  });

  testWidgets('cancellation between layout frames stops later locator jumps',
      (tester) async {
    final controller = ScrollController();
    final keys = <String, GlobalKey>{};
    final ids = List.generate(80, (index) => 'event-$index');
    await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
            height: 300,
            child: ListView.builder(
                controller: controller,
                reverse: true,
                itemCount: ids.length,
                itemBuilder: (_, index) => SizedBox(
                    key: keys.putIfAbsent(ids[index], GlobalKey.new),
                    height: 60)))));
    var cancelled = false;
    bool? result;
    final operation = revealLazyMessage(
        controller: controller,
        eventIds: ids,
        messageKeys: keys,
        eventId: ids.last,
        isMounted: () => true,
        canContinue: () => !cancelled).then((value) => result = value);
    final firstJumpOffset = controller.offset;
    expect(firstJumpOffset, greaterThan(0));
    cancelled = true;
    await tester.pump();
    await operation;
    expect(result, isFalse);
    expect(controller.offset, firstJumpOffset);
    await tester.pump();
    expect(controller.offset, firstJumpOffset);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('reveals a distant row within the bounded 200-row window',
      (tester) async {
    final controller = ScrollController();
    final keys = <String, GlobalKey>{};
    final ids = List.generate(200, (i) => 'tall-event-$i');
    await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
            child: SizedBox(
          width: 360,
          height: 500,
          child: ListView.builder(
              controller: controller,
              reverse: true,
              itemCount: ids.length,
              itemBuilder: (_, i) => SizedBox(
                  key: keys.putIfAbsent(ids[i], GlobalKey.new), height: 5000)),
        ))));
    bool? result;
    final operation = revealLazyMessage(
        controller: controller,
        eventIds: ids,
        messageKeys: keys,
        eventId: ids.last,
        isMounted: () => true).then((value) => result = value);
    for (var frame = 0; frame < 320 && result == null; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await operation;
    expect(result, isTrue);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('anchor restoration does not cancel an active reverse-list drag',
      (tester) async {
    final controller = ScrollController();
    final viewportKey = GlobalKey();
    final keys = <String, GlobalKey>{};
    var start = 300;
    late StateSetter update;
    List<String> ids() => List.generate(200, (i) => '${start + 199 - i}');
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 360,
            height: 500,
            child: StatefulBuilder(
              builder: (_, setState) {
                update = setState;
                final items = ids();
                return SizedBox(
                  key: viewportKey,
                  child: ListView.builder(
                    controller: controller,
                    reverse: true,
                    itemCount: items.length,
                    findChildIndexCallback: (key) => key is ValueKey<String>
                        ? items.indexOf(key.value)
                        : null,
                    itemBuilder: (_, index) => SizedBox(
                      key: ValueKey(items[index]),
                      child: SizedBox(
                        key: keys.putIfAbsent(items[index], GlobalKey.new),
                        height: [
                          44.0,
                          120.0,
                          240.0,
                          64.0
                        ][int.parse(items[index]) % 4],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    controller.jumpTo(16000);
    await tester.pump();
    final anchor = TimelineScrollAnchor.capture(keys, viewportKey)!;
    update(() => start = 200);
    await tester.pump();
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(ListView)));
    await gesture.moveBy(const Offset(0, -80));
    expect(controller.position.isScrollingNotifier.value, isTrue);
    final restoration = anchor.restore(
        controller: controller,
        keys: keys,
        eventIds: ids(),
        isMounted: () => true,
        canRestore: () => !controller.position.isScrollingNotifier.value);
    for (var frame = 0; frame < 120; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await restoration;
    expect(controller.position.isScrollingNotifier.value, isTrue);
    await gesture.up();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}

class _TrackedMessage extends StatefulWidget {
  const _TrackedMessage(
      {super.key,
      required this.height,
      required this.onMount,
      required this.onUnmount});
  final double height;
  final VoidCallback onMount;
  final VoidCallback onUnmount;
  @override
  State<_TrackedMessage> createState() => _TrackedMessageState();
}

class _TrackedMessageState extends State<_TrackedMessage> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  void dispose() {
    widget.onUnmount();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(height: widget.height);
}
