import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:liuhetong_mobile/features/matrix/room_image_preview_cache.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:liuhetong_mobile/features/matrix/media_consumer_scope.dart';
import 'package:liuhetong_mobile/ui/chat/budgeted_media_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/contain_image_bubble.dart';
import 'package:liuhetong_mobile/ui/chat/encrypted_media_view.dart';

void main() {
  final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
  testWidgets('warm reentry paints decoded pixels in the first frame',
      (tester) async {
    var reads = 0;
    RoomImagePreviewCache cache() => RoomImagePreviewCache.forRoomSession(
        accountId: 'account',
        roomId: 'room',
        read: (_) async => null,
        write: (_, __) async {});
    RoomImagePreviewCache.clearSessionMemory();
    var previews = cache()..seed('content', png);
    final warm = previews.get('content')!;
    addTearDown(() {
      previews.dispose();
      RoomImagePreviewCache.clearSessionMemory();
    });
    Widget bubble() => CupertinoApp(
            home: Center(
                child: ContainImageBubble(
          initialBytes: previews.get('content'),
          sourceIdentity: 'account/room/content',
          loadCached: () async {
            reads++;
            return null;
          },
          load: () async {
            reads++;
            return png;
          },
        )));
    await tester.pumpWidget(bubble());
    await tester.runAsync(() => precacheImage(boundedChatImageProvider(warm),
        tester.element(find.byType(ContainImageBubble))));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    previews.dispose();
    previews = cache();
    await tester.pumpWidget(bubble());
    final pixels = find.byType(RawImage);
    expect(pixels, findsOneWidget);
    expect(tester.renderObject<RenderImage>(pixels).image, isNotNull);
    expect(reads, 0);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'explicit original reopens from authorized local cache without network',
      (tester) async {
    Uint8List? saved;
    var network = 0;
    Widget page() => CupertinoApp(
            home: ImageViewerPage(
          previewBytes: png,
          sourceIdentity: 'account/room/content',
          peekOriginal: () => saved,
          readCachedOriginal: () async => saved,
          loadOriginal: () async {
            network++;
            return saved = png;
          },
        ));
    await tester.pumpWidget(page());
    await tester.pump();
    expect(network, 0);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('viewer-view-original')));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(network, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    expect(find.textContaining('已展示原图'), findsOneWidget);
    expect(network, 1);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'cold cached original resumes after cancellation and never invokes network',
      (tester) async {
    final held = Completer<Uint8List?>();
    MediaConsumerScope? scope;
    var probes = 0, network = 0;
    Widget page(bool active) => CupertinoApp(
            home: ImageViewerPage(
          key: const ValueKey('same-viewer'),
          previewBytes: png,
          sourceIdentity: 'account/room/content',
          active: active,
          readCachedOriginal: () {
            scope = MediaConsumerScope.current;
            return ++probes == 1 ? held.future : Future.value(png);
          },
          loadOriginal: () async {
            network++;
            return png;
          },
        ));
    await tester.pumpWidget(page(true));
    await tester.pump();
    expect(probes, 1);
    final canceled = scope!;
    await tester.pumpWidget(page(false));
    expect(canceled.isActive, isFalse);
    await tester.runAsync(() async {
      held.complete(png);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(find.textContaining('已展示原图'), findsNothing);
    await tester.runAsync(() async {
      await tester.pumpWidget(page(true));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(probes, 2);
    expect(network, 0);
    expect(find.textContaining('已展示原图'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'account content and revoked cache miss discard the previous original',
      (tester) async {
    var network = 0;
    Widget page(String identity, Uint8List? cached, {bool fail = false}) =>
        CupertinoApp(
            home: ImageViewerPage(
          key: const ValueKey('same-viewer'),
          previewBytes: png,
          sourceIdentity: identity,
          peekOriginal: () => cached,
          readCachedOriginal: () async {
            if (fail) throw StateError('cache unavailable');
            return cached;
          },
          loadOriginal: () async {
            network++;
            return png;
          },
        ));
    await tester.pumpWidget(page('a/room/one', png));
    expect(find.textContaining('已展示原图'), findsOneWidget);
    for (final identity in ['b/room/one', 'b/room/two', 'b/revoked/two']) {
      await tester
          .pumpWidget(page(identity, null, fail: identity.contains('revoked')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('已展示原图'), findsNothing);
      expect(find.textContaining('查看原图'), findsOneWidget);
      expect(find.textContaining('加载失败'), findsNothing);
      expect(network, 0);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cleared decoded cache and warm GIF keep initial decode gated',
      (tester) async {
    final provider = boundedChatImageProvider(png);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    await tester.runAsync(() =>
        precacheImage(provider, tester.element(find.byType(SizedBox).first)));
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    Widget image(bool animated) => CupertinoApp(
        home: BudgetedMediaImage(
            provider: provider,
            isAnimated: animated,
            visible: false,
            priority: 0));
    await tester.pumpWidget(image(false));
    expect(find.byType(RawImage), findsNothing);
    await tester.runAsync(() => precacheImage(
        provider, tester.element(find.byType(BudgetedMediaImage))));
    await tester.pumpWidget(image(true));
    expect(find.byType(RawImage), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('forward action shows progress and reports failure',
      (tester) async {
    final held = Completer<void>();
    await tester.pumpWidget(CupertinoApp(
        home:
            ImageViewerPage(previewBytes: png, onForward: () => held.future)));
    await tester.pump();
    await tester.tap(find.byKey(const Key('viewer-forward')));
    await tester.pump();
    expect(find.text('转发中'), findsOneWidget);
    expect(
        tester
            .widget<ViewerRoundAction>(find.byKey(const Key('viewer-forward')))
            .onPressed,
        isNull);
    held.completeError(StateError('synthetic forwarding failure'));
    await tester.pump();
    expect(find.text('转发失败，请重试'), findsOneWidget);
    expect(
        tester
            .widget<ViewerRoundAction>(find.byKey(const Key('viewer-forward')))
            .onPressed,
        isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'narrow viewer has horizontal internal-label actions above safe area',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(CupertinoApp(
        home: MediaQuery(
            data: const MediaQueryData(
                size: Size(320, 640), padding: EdgeInsets.only(bottom: 34)),
            child: ImageViewerPage(
                previewBytes: png,
                loadOriginal: () async => png,
                onForward: () async {}))));
    await tester.pump();
    final edit = tester.getRect(find.byKey(const Key('viewer-edit')));
    final download = tester.getRect(find.byKey(const Key('viewer-download')));
    final forward = tester.getRect(find.byKey(const Key('viewer-forward')));
    expect(edit.center.dy, download.center.dy);
    expect(download.center.dy, forward.center.dy);
    expect(edit.right, lessThanOrEqualTo(download.left));
    expect(forward.bottom, lessThanOrEqualTo(606));
    for (final label in ['编辑', '下载', '转发']) {
      expect(
          find.ancestor(
              of: find.text(label), matching: find.byType(CupertinoButton)),
          findsOneWidget);
    }
    expect(
        tester
            .getRect(find.byKey(const Key('viewer-view-original')))
            .overlaps(edit),
        isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
