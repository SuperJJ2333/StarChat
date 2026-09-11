import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/media_visibility.dart';

Widget _list(ScrollController controller, ValueChanged<bool> changed) =>
    CupertinoApp(
        home: ListView.builder(
      controller: controller,
      scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
      itemCount: 20,
      itemBuilder: (_, index) => SizedBox(
        height: 100,
        child: index == 0
            ? MediaVisibility(
                onChanged: changed, child: const SizedBox.expand())
            : const SizedBox.expand(),
      ),
    ));

void main() {
  testWidgets('reports visible, offscreen while mounted, then visible again',
      (tester) async {
    final values = <bool>[];
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_list(controller, values.add));
    await tester.pump();
    expect(values, [true]);
    controller.jumpTo(400);
    await tester.pump();
    expect(find.byType(MediaVisibility, skipOffstage: false), findsOneWidget);
    expect(values.last, false);
    controller.jumpTo(0);
    await tester.pump();
    expect(values.last, true);
  });

  testWidgets('background, route cover, and disposal report false once',
      (tester) async {
    final values = <bool>[];
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(CupertinoApp(
        navigatorKey: navigator,
        home: MediaVisibility(
            onChanged: values.add, child: const SizedBox.expand())));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump();
    expect(values.last, false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    navigator.currentState!
        .push(CupertinoPageRoute<void>(builder: (_) => const SizedBox()));
    await tester.pumpAndSettle();
    expect(values.last, false);
    final count = values.length;
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(values.length, count);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('route return and ticker mode restore visibility',
      (tester) async {
    final values = <bool>[];
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(CupertinoApp(
        navigatorKey: navigator,
        home: MediaVisibility(
            onChanged: values.add, child: const SizedBox.expand())));
    await tester.pump();
    navigator.currentState!
        .push(CupertinoPageRoute<void>(builder: (_) => const SizedBox()));
    await tester.pumpAndSettle();
    expect(values.last, false);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(values.last, true);
    await tester.pumpWidget(CupertinoApp(
        home: TickerMode(
            enabled: false,
            child: MediaVisibility(
                onChanged: values.add, child: const SizedBox.expand()))));
    await tester.pump();
    expect(values.last, false);
    await tester.pumpWidget(CupertinoApp(
        home: TickerMode(
            enabled: true,
            child: MediaVisibility(
                onChanged: values.add, child: const SizedBox.expand()))));
    await tester.pump();
    expect(values.last, true);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('horizontal cached child reports offscreen and return',
      (tester) async {
    final values = <bool>[];
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(CupertinoApp(
        home: ListView(
            scrollDirection: Axis.horizontal,
            controller: controller,
          scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
            children: [
          SizedBox(
              width: 100,
              child: MediaVisibility(
                  onChanged: values.add, child: const SizedBox.expand())),
          const SizedBox(width: 1000)
        ])));
    await tester.pump();
    controller.jumpTo(300);
    await tester.pump();
    expect(values.last, false);
    controller.jumpTo(0);
    await tester.pump();
    expect(values.last, true);
    await tester.pumpWidget(const SizedBox());
  });
}
