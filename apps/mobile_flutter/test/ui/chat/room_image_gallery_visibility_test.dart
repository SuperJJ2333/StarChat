import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_consumer_scope.dart';
import 'package:liuhetong_mobile/ui/chat/budgeted_media_image.dart';
import 'package:liuhetong_mobile/ui/chat/encrypted_media_view.dart';
import 'package:liuhetong_mobile/ui/chat/room_image_gallery.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'inactive gallery cancels held previews and resumes only the missing window',
      (tester) async {
    final previews = _HeldPreviews();
    try {
      await tester.pumpWidget(_gallery(
          images: previews.images(5), initialId: 'image-2', source: 'a'));
      await tester.pump();
      expect(previews.ids, unorderedEquals(['image-1', 'image-2', 'image-3']));

      previews.latest('image-2').complete(_png());
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(previews.latest('image-1').scope.isActive, isFalse);
      expect(previews.latest('image-3').scope.isActive, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(previews.calls('image-1'), 2);
      expect(previews.calls('image-3'), 2);
      expect(previews.calls('image-2'), 1,
          reason: 'a completed current preview remains reusable');
      expect(previews.ids, unorderedEquals(['image-1', 'image-2', 'image-3']));
      expect(find.byKey(const ValueKey('viewer-image-2')), findsOneWidget);
    } finally {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
      previews.completeAll();
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('a covered gallery cancels preview owners and rewarms on return',
      (tester) async {
    final previews = _HeldPreviews();
    try {
      await tester.pumpWidget(_gallery(
          images: previews.images(5), initialId: 'image-2', source: 'a'));
      await tester.pump();
      final routeContext = tester.element(find.byType(RoomImageGalleryPage));

      Navigator.of(routeContext).push(CupertinoPageRoute<void>(
          builder: (_) => const CupertinoPageScaffold(child: SizedBox())));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(previews.latest('image-1').scope.isActive, isFalse);
      expect(previews.latest('image-2').scope.isActive, isFalse);
      expect(previews.latest('image-3').scope.isActive, isFalse);

      Navigator.of(routeContext).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(previews.calls('image-1'), 2);
      expect(previews.calls('image-2'), 2);
      expect(previews.calls('image-3'), 2);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      previews.completeAll();
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('a source replacement while inactive waits until visible',
      (tester) async {
    final first = _HeldPreviews();
    final replacement = _HeldPreviews();
    try {
      await tester.pumpWidget(
          _gallery(images: first.images(5), initialId: 'image-2', source: 'a'));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();

      await tester.pumpWidget(_gallery(
          images: replacement.images(5), initialId: 'image-2', source: 'b'));
      await tester.pump();
      expect(replacement.ids, isEmpty,
          reason: 'a hidden source must not begin preview transport');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(
          replacement.ids, unorderedEquals(['image-1', 'image-2', 'image-3']));
      expect(first.scopes.every((scope) => !scope.isActive), isTrue);
    } finally {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
      first.completeAll();
      replacement.completeAll();
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('disposing a gallery cancels held previews without an error',
      (tester) async {
    final previews = _HeldPreviews();
    try {
      await tester.pumpWidget(_gallery(
          images: previews.images(5), initialId: 'image-2', source: 'a'));
      await tester.pump();
      expect(previews.scopes.toList(), hasLength(3));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(previews.scopes.every((scope) => !scope.isActive), isTrue);
      previews.completeAll();
      await tester.pump();
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      previews.completeAll();
      await tester.pump();
    }
  });

  testWidgets('an initially empty visible gallery loads its first history page',
      (tester) async {
    var historyCalls = 0;
    try {
      await tester.pumpWidget(_gallery(
          images: const [],
          initialId: 'history-image',
          source: 'empty',
          loadEarlier: () async {
            historyCalls++;
            return [_image('history-image')];
          }));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(historyCalls, 1);
      expect(
          find.byKey(const ValueKey('viewer-history-image')), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('an inactive gallery that becomes empty resumes history loading',
      (tester) async {
    final previews = _HeldPreviews();
    var historyCalls = 0;
    try {
      await tester.pumpWidget(_gallery(
          images: previews.images(3), initialId: 'image-1', source: 'a'));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();

      await tester.pumpWidget(_gallery(
          images: const [],
          initialId: 'history-after-hidden',
          source: 'b',
          loadEarlier: () async {
            historyCalls++;
            return [_image('history-after-hidden')];
          }));
      await tester.pump();
      expect(historyCalls, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(historyCalls, 1);
      expect(find.byKey(const ValueKey('viewer-history-after-hidden')),
          findsOneWidget);
    } finally {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
      previews.completeAll();
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('only the current gallery viewer is active for animated media',
      (tester) async {
    final previews = _HeldPreviews();
    try {
      await tester.pumpWidget(_gallery(
          images: previews.images(5), initialId: 'image-2', source: 'a'));
      await tester.pump();
      for (final id in ['image-1', 'image-2', 'image-3']) {
        previews.latest(id).complete(_gif());
      }
      await tester.pump();
      await tester.pump();
      final pages = find.byType(PageView);
      final pageController = tester.widget<PageView>(pages).controller!;
      expect(pageController.page, closeTo(2, .01));
      final gesture = await tester.startGesture(tester.getCenter(pages));
      await gesture.moveBy(const Offset(-50, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-250, 0));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(pageController.page, greaterThan(2));

      final mounted = find.byType(ImageViewerPage, skipOffstage: false);
      expect(mounted, findsAtLeastNWidgets(2));
      _expectViewerEligibility(tester, 'image-2', active: true);
      _expectViewerEligibility(tester, 'image-3', active: false);

      await gesture.moveBy(const Offset(-250, 0));
      await tester.pump(const Duration(milliseconds: 350));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 500));
      _expectViewerEligibility(tester, 'image-3', active: true);
      final oldViewer =
          find.byKey(const ValueKey('viewer-image-2'), skipOffstage: false);
      if (oldViewer.evaluate().isNotEmpty) {
        _expectViewerEligibility(tester, 'image-2', active: false);
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      previews.completeAll();
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('pinching or panning a zoomed viewer does not turn the page',
      (tester) async {
    final previews = _HeldPreviews();
    try {
      await tester.pumpWidget(_gallery(
          images: previews.images(5), initialId: 'image-2', source: 'a'));
      await tester.pump();
      previews.latest('image-2').complete(_png());
      await tester.pumpAndSettle();

      final pages = find.byType(PageView);
      final controller = tester.widget<PageView>(pages).controller!;
      final center = tester.getCenter(pages);
      final first =
          await tester.startGesture(center - const Offset(40, 0), pointer: 1);
      final second =
          await tester.startGesture(center + const Offset(40, 0), pointer: 2);
      await first.moveBy(const Offset(-50, 0));
      await second.moveBy(const Offset(50, 0));
      await tester.pump();
      await second.up();
      await first.up();
      await tester.pump();
      expect(controller.page, closeTo(2, .01));

      final interactive = find.descendant(
          of: find.byKey(const ValueKey('viewer-image-2')),
          matching: find.byType(InteractiveViewer));
      final transform = tester
          .widget<InteractiveViewer>(interactive)
          .transformationController!
          .value;
      expect(transform.getMaxScaleOnAxis(), greaterThan(1));
      final translationBeforePan = transform.getTranslation();

      await tester.drag(pages, const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(controller.page, closeTo(2, .01));
      final translationAfterPan = tester
          .widget<InteractiveViewer>(interactive)
          .transformationController!
          .value
          .getTranslation();
      expect(translationAfterPan, isNot(translationBeforePan));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      previews.completeAll();
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
      'a canceled drag cannot strand a fresh decoded-image swipe after visibility or source changes',
      (tester) async {
    Future<void> exercise({required bool replaceScope}) async {
      final original = _HeldPreviews();
      final replacement = _HeldPreviews();
      try {
        await tester.pumpWidget(_gallery(
            images: original.images(5), initialId: 'image-2', source: 'a'));
        await tester.pump();
        for (final id in ['image-1', 'image-2', 'image-3']) {
          original.latest(id).complete(_png());
        }
        await tester.pumpAndSettle();

        var pages = find.byType(PageView);
        var controller = tester.widget<PageView>(pages).controller!;
        final stale = await tester.startGesture(tester.getCenter(pages));
        await stale.moveBy(const Offset(-50, 0));
        await tester.pump();
        await stale.moveBy(const Offset(-250, 0));
        await tester.pump(const Duration(milliseconds: 16));
        expect(controller.page, greaterThan(2));

        if (replaceScope) {
          await tester.pumpWidget(_gallery(
              images: replacement.images(5),
              initialId: 'image-2',
              source: 'b'));
          await tester.pump();
          for (final id in ['image-1', 'image-2', 'image-3']) {
            replacement.latest(id).complete(_png());
          }
          await tester.pumpAndSettle();
        } else {
          tester.binding
              .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          await tester.pump();
          tester.binding
              .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await tester.pumpAndSettle();
        }
        await stale.up();
        await tester.pump();

        pages = find.byType(PageView);
        controller = tester.widget<PageView>(pages).controller!;
        expect(controller.page, closeTo(2, .01));
        final fresh = await tester.startGesture(tester.getCenter(pages));
        await fresh.moveBy(const Offset(-50, 0));
        await tester.pump();
        await fresh.moveBy(const Offset(-250, 0));
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        expect(controller.page, greaterThan(2));
        await fresh.up();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(const SizedBox.shrink());
        original.completeAll();
        replacement.completeAll();
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    }

    await exercise(replaceScope: false);
    await exercise(replaceScope: true);
  });
}

void _expectViewerEligibility(WidgetTester tester, String id,
    {required bool active}) {
  final viewer = find.byKey(ValueKey('viewer-$id'), skipOffstage: false);
  expect(viewer, findsOneWidget);
  expect(tester.widget<ImageViewerPage>(viewer).active, active);

  final budgeted = find.descendant(
      of: viewer,
      matching: find.byType(BudgetedMediaImage, skipOffstage: false));
  expect(budgeted, findsOneWidget);
  expect(tester.widget<BudgetedMediaImage>(budgeted).visible, active);

  final image = find.descendant(
      of: viewer, matching: find.byType(Image, skipOffstage: false));
  if (active) {
    expect(image, findsOneWidget);
    expect(TickerMode.valuesOf(tester.element(image)).enabled, isTrue);
  } else {
    expect(image, anyOf(findsNothing, findsOneWidget));
    if (image.evaluate().isNotEmpty) {
      expect(TickerMode.valuesOf(tester.element(image)).enabled, isFalse);
    }
  }
}

Widget _gallery({
  required List<RoomGalleryImage> images,
  required String initialId,
  required Object source,
  Future<List<RoomGalleryImage>> Function()? loadEarlier,
}) =>
    CupertinoApp(
        home: RoomImageGalleryPage(
            images: images,
            initialId: initialId,
            sourceScope: ('metrics', 'room', source),
            loadEarlier: loadEarlier ?? () async => const <RoomGalleryImage>[],
            onForwardEdited: (_) async => false,
            onFavorite: (_) async {}));

RoomGalleryImage _image(String id) => RoomGalleryImage(
    id: id,
    sourceIdentity: 'source-$id',
    loadPreview: () async => _png(),
    loadOriginal: () async => _png(),
    onForward: () async {});

final class _HeldPreviews {
  final _attempts = <String, List<_PreviewAttempt>>{};

  Iterable<String> get ids => _attempts.keys;
  Iterable<MediaConsumerScope> get scopes => _attempts.values
      .expand((attempts) => attempts.map((entry) => entry.scope));

  int calls(String id) => _attempts[id]?.length ?? 0;
  _PreviewAttempt latest(String id) => _attempts[id]!.last;

  List<RoomGalleryImage> images(int count) => List.generate(
      count,
      (index) => RoomGalleryImage(
          id: 'image-$index',
          sourceIdentity: 'source-$index',
          loadPreview: () {
            final scope = MediaConsumerScope.current!;
            final attempt = _PreviewAttempt(scope);
            _attempts.putIfAbsent('image-$index', () => []).add(attempt);
            return attempt.future;
          },
          loadOriginal: () async => _png(),
          onForward: () async {}));

  void completeAll() {
    for (final attempt in _attempts.values.expand((attempts) => attempts)) {
      if (!attempt.completer.isCompleted) attempt.complete(_png());
    }
  }
}

final class _PreviewAttempt {
  _PreviewAttempt(this.scope);

  final MediaConsumerScope scope;
  final completer = Completer<Uint8List>();
  Future<Uint8List> get future => completer.future;
  void complete(Uint8List bytes) {
    if (!completer.isCompleted) completer.complete(bytes);
  }
}

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
