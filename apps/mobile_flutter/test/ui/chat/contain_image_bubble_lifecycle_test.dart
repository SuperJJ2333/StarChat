import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/media_consumer_scope.dart';
import 'package:liuhetong_mobile/ui/chat/contain_image_bubble.dart';

void main() {
  testWidgets('an offscreen cached bubble cancels its final consumer',
      (tester) async {
    final controller = ScrollController();
    final cache = MediaMemoryCache();
    final held = Completer<Uint8List>();
    MediaConsumerScope? bubbleScope;
    var sourceCalls = 0;
    Future<Uint8List> load() {
      bubbleScope = MediaConsumerScope.current;
      return cache.putIfAbsent('shared', () {
        sourceCalls++;
        return held.future;
      });
    }

    try {
      await tester.pumpWidget(_scrollingBubbles(
          controller: controller,
          first: _bubble('first', load),
          second: const SizedBox(height: 500)));
      await tester.pump();
      await tester.pump();
      expect(sourceCalls, 1);
      expect(bubbleScope, isNotNull);

      controller.jumpTo(300);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('first'), skipOffstage: false),
          findsOneWidget);
      expect(bubbleScope!.isActive, isFalse);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!held.isCompleted) held.complete(_png());
      cache.dispose();
      controller.dispose();
      await tester.pump();
    }
  });

  testWidgets(
      'a visible peer retains one shared load after the first scrolls off',
      (tester) async {
    final controller = ScrollController();
    final cache = MediaMemoryCache();
    final held = Completer<Uint8List>();
    MediaConsumerScope? firstScope;
    MediaConsumerScope? secondScope;
    var sourceCalls = 0;
    Future<Uint8List> load(bool first) {
      if (first) {
        firstScope = MediaConsumerScope.current;
      } else {
        secondScope = MediaConsumerScope.current;
      }
      return cache.putIfAbsent('shared', () {
        sourceCalls++;
        return held.future;
      });
    }

    try {
      await tester.pumpWidget(_scrollingBubbles(
          controller: controller,
          first: _bubble('first', () => load(true)),
          second: _bubble('second', () => load(false))));
      await tester.pump();
      await tester.pump();
      expect(sourceCalls, 1);
      controller.jumpTo(300);
      await tester.pump();
      await tester.pump();

      expect(firstScope!.isActive, isFalse);
      expect(secondScope!.isActive, isTrue);
      expect(sourceCalls, 1);
      held.complete(_png());
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!held.isCompleted) held.complete(_png());
      cache.dispose();
      controller.dispose();
      await tester.pump();
    }
  });

  testWidgets(
      'a returning bubble retries cancellation without showing an error',
      (tester) async {
    final controller = ScrollController();
    final cache = MediaMemoryCache();
    final held = [Completer<Uint8List>(), Completer<Uint8List>()];
    var sourceCalls = 0;
    Future<Uint8List> load() => cache.putIfAbsent('retry', () {
          final next = held[sourceCalls++];
          return next.future;
        });

    try {
      await tester.pumpWidget(_scrollingBubbles(
          controller: controller,
          first: _bubble('first', load),
          second: const SizedBox(height: 500)));
      await tester.pump();
      await tester.pump();
      expect(sourceCalls, 1);
      controller.jumpTo(300);
      await tester.pump();
      await tester.pump();
      controller.jumpTo(0);
      await tester.pump();
      await tester.pump();

      expect(sourceCalls, 2);
      expect(find.text('图片加载失败，点击重试'), findsNothing);
      held[1].complete(_png());
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      for (final completer in held) {
        if (!completer.isCompleted) completer.complete(_png());
      }
      cache.dispose();
      controller.dispose();
      await tester.pump();
    }
  });

  testWidgets('a same-key source replacement ignores a late old image',
      (tester) async {
    final old = Completer<Uint8List>();
    final fresh = Completer<Uint8List>();
    try {
      await tester.pumpWidget(CupertinoApp(
          home: Center(
              child: _bubble('same', () => old.future,
                  sourceIdentity: 'preview-a'))));
      await tester.pump();
      await tester.pumpWidget(CupertinoApp(
          home: Center(
              child: _bubble('same', () => fresh.future,
                  sourceIdentity: 'preview-b'))));
      await tester.pump();
      fresh.complete(_taggedPng(0x42));
      await tester.pump();
      await tester.pump();
      expect(_renderedBytes(tester), _taggedPng(0x42));

      old.complete(_taggedPng(0x41));
      await tester.pump();
      await tester.pump();
      expect(_renderedBytes(tester), _taggedPng(0x42));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!old.isCompleted) old.complete(_taggedPng(0x41));
      if (!fresh.isCompleted) fresh.complete(_taggedPng(0x42));
      await tester.pump();
    }
  });

  testWidgets(
      'a completed refresh source is not reloaded after visibility returns',
      (tester) async {
    final controller = ScrollController();
    var sourceCalls = 0;
    try {
      await tester.pumpWidget(_scrollingBubbles(
          controller: controller,
          first: ContainImageBubble(
              key: const ValueKey('refresh'),
              initialBytes: _png(),
              refreshFromSource: true,
              load: () async {
                sourceCalls++;
                return _png();
              },
              sourceSize: const Size(20, 20)),
          second: const SizedBox(height: 500)));
      await tester.pump();
      await tester.pump();
      expect(sourceCalls, 1);

      controller.jumpTo(300);
      await tester.pump();
      await tester.pump();
      controller.jumpTo(0);
      await tester.pump();
      await tester.pump();
      expect(sourceCalls, 1);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    }
  });

  testWidgets('an offscreen initial GIF is not animation-eligible',
      (tester) async {
    final controller = ScrollController(initialScrollOffset: 300);
    try {
      await tester.pumpWidget(_scrollingBubbles(
          controller: controller,
          first: ContainImageBubble(
              key: const ValueKey('initial-gif'),
              initialBytes: _gif(),
              load: () async => _gif(),
              sourceSize: const Size(20, 20)),
          second: const SizedBox(height: 500)));
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image, skipOffstage: false), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    }
  });
}

Widget _scrollingBubbles({
  required ScrollController controller,
  required Widget first,
  required Widget second,
}) =>
    CupertinoApp(
        home: ListView(
            controller: controller,
            scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
            children: [
          SizedBox(height: 250, child: Center(child: first)),
          SizedBox(height: 250, child: Center(child: second)),
          const SizedBox(height: 500),
        ]));

ContainImageBubble _bubble(String id, Future<Uint8List> Function() load,
        {Object? sourceIdentity}) =>
    ContainImageBubble(
        key: ValueKey(id),
        sourceIdentity: sourceIdentity,
        load: load,
        sourceSize: const Size(20, 20));

Uint8List _renderedBytes(WidgetTester tester) {
  final image = tester.widget<Image>(find.byType(Image));
  final resize = image.image as ResizeImage;
  return (resize.imageProvider as MemoryImage).bytes;
}

Uint8List _taggedPng(int tag) => Uint8List.fromList([..._png(), tag]);

Uint8List _png() => Uint8List.fromList(const [
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
      0x00,
      0x00,
      0x00,
      0x0d,
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
      0x1f,
      0x15,
      0xc4,
      0x89,
      0x00,
      0x00,
      0x00,
      0x0d,
      0x49,
      0x44,
      0x41,
      0x54,
      0x08,
      0xd7,
      0x63,
      0xf8,
      0xcf,
      0xc0,
      0xf0,
      0x1f,
      0x00,
      0x05,
      0x00,
      0x01,
      0xff,
      0x89,
      0x99,
      0x3d,
      0x1d,
      0x00,
      0x00,
      0x00,
      0x00,
      0x49,
      0x45,
      0x4e,
      0x44,
      0xae,
      0x42,
      0x60,
      0x82,
    ]);

Uint8List _gif() => Uint8List.fromList(const [
      71,
      73,
      70,
      56,
      57,
      97,
      1,
      0,
      1,
      0,
      128,
      0,
      0,
      0,
      0,
      0,
      255,
      255,
      255,
      33,
      249,
      4,
      1,
      0,
      0,
      0,
      0,
      44,
      0,
      0,
      0,
      0,
      1,
      0,
      1,
      0,
      0,
      2,
      2,
      68,
      1,
      0,
      59,
    ]);
