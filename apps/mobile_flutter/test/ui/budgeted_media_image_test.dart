import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/budgeted_media_image.dart';
import 'package:liuhetong_mobile/ui/chat/media_activity.dart';

Uint8List _png() => Uint8List.fromList(const [
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0x00,
      0x00,
      0x00,
      0x0D,
      0x49,
      0x48,
      0x44,
      0x52,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x08,
      0x06,
      0x00,
      0x00,
      0x00,
      0x1F,
      0x15,
      0xC4,
      0x89,
      0x00,
      0x00,
      0x00,
      0x0A,
      0x49,
      0x44,
      0x41,
      0x54,
      0x78,
      0x9C,
      0x63,
      0x00,
      0x01,
      0x00,
      0x00,
      0x05,
      0x00,
      0x01,
      0x0D,
      0x0A,
      0x2D,
      0xB4,
      0x00,
      0x00,
      0x00,
      0x00,
      0x49,
      0x45,
      0x4E,
      0x44,
      0xAE,
      0x42,
      0x60,
      0x82
    ]);

void main() {
  testWidgets('three animated images grant at most two tickers',
      (tester) async {
    final budget = MediaAnimationBudget(maxActive: 2);
    final provider = MemoryImage(_png());
    try {
      await tester.pumpWidget(CupertinoApp(
          home: Row(
              children: List.generate(
                  3,
                  (index) => BudgetedMediaImage(
                      key: ValueKey(index),
                      provider: provider,
                      isAnimated: true,
                      visible: true,
                      priority: 0,
                      budget: budget)))));
      await tester.pumpAndSettle();
      await tester.runAsync(
          () => precacheImage(provider, tester.element(find.byType(Row))));
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image), findsNWidgets(3));
      for (var index = 0; index < 3; index++) {
        final image = find.descendant(
            of: find.byKey(ValueKey(index)), matching: find.byType(Image));
        final raw = find.descendant(of: image, matching: find.byType(RawImage));
        expect(tester.renderObject<RenderImage>(raw).image, isNotNull);
        expect(TickerMode.valuesOf(image.evaluate().single).enabled, index < 2);
      }
    } finally {
      await tester.pumpWidget(const SizedBox());
    }
  });
  testWidgets('same key switches animated mode without stale listeners',
      (tester) async {
    final provider = MemoryImage(_png());
    Widget build(bool animated) => CupertinoApp(
        home: BudgetedMediaImage(
            key: const ValueKey('media'),
            provider: provider,
            isAnimated: animated,
            visible: true,
            priority: 0));
    try {
      await tester.pumpWidget(build(true));
      await tester.pumpWidget(build(false));
      await tester.pumpWidget(build(true));
      await tester.pump();
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('default budget caps three animated images at two',
      (tester) async {
    final provider = MemoryImage(_png());
    try {
      await tester.pumpWidget(CupertinoApp(
          home: Row(
              children: List.generate(
                  3,
                  (i) => BudgetedMediaImage(
                      key: ValueKey('d$i'),
                      provider: provider,
                      isAnimated: true,
                      visible: true,
                      priority: 0)))));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNWidgets(3));
      expect(
          find
              .byType(Image)
              .evaluate()
              .where((e) => TickerMode.valuesOf(e).enabled)
              .length,
          2);
    } finally {
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('hidden image is absent until visible and retained after hiding',
      (tester) async {
    final provider = MemoryImage(_png());
    Widget build(bool visible) => CupertinoApp(
        home: Center(
            child: BudgetedMediaImage(
                key: const ValueKey('hidden'),
                provider: provider,
                isAnimated: true,
                visible: visible,
                priority: 0,
                width: 40,
                height: 30)));
    try {
      await tester.pumpWidget(build(false));
      expect(find.byType(Image), findsNothing);
      expect(
          tester.getSize(find.byType(BudgetedMediaImage)), const Size(40, 30));
      await tester.pumpWidget(build(true));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      await tester.pumpWidget(build(false));
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('viewer preempts a thumbnail without exceeding two tickers',
      (tester) async {
    final budget = MediaAnimationBudget(maxActive: 2);
    final provider = MemoryImage(_png());
    Widget build(bool viewer) => CupertinoApp(
            home: Row(children: [
          BudgetedMediaImage(
              key: const ValueKey('A'),
              provider: provider,
              isAnimated: true,
              visible: true,
              priority: 0,
              budget: budget),
          BudgetedMediaImage(
              key: const ValueKey('B'),
              provider: provider,
              isAnimated: true,
              visible: true,
              priority: 0,
              budget: budget),
          if (viewer)
            BudgetedMediaImage(
                key: const ValueKey('V'),
                provider: provider,
                isAnimated: true,
                visible: true,
                priority: 100,
                budget: budget)
        ]));
    try {
      await tester.pumpWidget(build(false));
      await tester.pumpAndSettle();
      await tester.pumpWidget(build(true));
      expect(
          find
              .byType(Image)
              .evaluate()
              .where((e) => TickerMode.valuesOf(e).enabled)
              .length,
          lessThanOrEqualTo(2));
      await tester.pump();
      for (final entry in [('A', true), ('B', false), ('V', true)]) {
        final finder = find.descendant(
            of: find.byKey(ValueKey(entry.$1)), matching: find.byType(Image));
        expect(TickerMode.valuesOf(finder.evaluate().single).enabled, entry.$2);
      }
    } finally {
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('same key provider replacement installs the new image',
      (tester) async {
    final first = MemoryImage(_png());
    final second = MemoryImage(Uint8List.fromList(_png()));
    Widget build(ImageProvider provider) => CupertinoApp(
        home: BudgetedMediaImage(
            key: const ValueKey('replace'),
            provider: provider,
            isAnimated: true,
            visible: true,
            priority: 0));
    try {
      await tester.pumpWidget(build(first));
      final oldElement = find.byType(Image).evaluate().single;
      await tester.pumpWidget(build(second));
      await tester.pump();
      expect((tester.widget<Image>(find.byType(Image)).image), second);
      expect(find.byType(Image).evaluate().single, isNot(same(oldElement)));
    } finally {
      await tester.pumpWidget(const SizedBox());
    }
  });
}
