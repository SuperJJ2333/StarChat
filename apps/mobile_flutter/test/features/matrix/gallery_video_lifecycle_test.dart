import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/gallery_video_preview.dart';
import 'package:liuhetong_mobile/features/matrix/video_transcode.dart';
import 'package:liuhetong_mobile/ui/chat/shared_video_playback.dart';
import 'package:video_player/video_player.dart';

final class _HeldPlayer extends VideoPlayerController {
  _HeldPlayer(
      {this.holdPlay = false,
      this.holdPause = false,
      this.failPause = false,
      this.failDispose = false,
      this.failPlayOnce = false})
      : super.file(File('unused'));
  final initialized = Completer<void>();
  final playStarted = Completer<void>();
  final playRelease = Completer<void>();
  final pauseStarted = Completer<void>();
  final pauseRelease = Completer<void>();
  bool holdPlay;
  bool holdPause;
  bool failPause;
  bool failDispose;
  bool failPlayOnce;
  var plays = 0;
  var pauses = 0;
  var disposals = 0;

  @override
  Future<void> initialize() async {
    await initialized.future;
    value = value.copyWith(isInitialized: true, size: const Size(10, 10));
  }

  @override
  Future<void> play() async {
    plays++;
    if (!playStarted.isCompleted) playStarted.complete();
    if (holdPlay) await playRelease.future;
    value = value.copyWith(isPlaying: true);
    if (failPlayOnce) {
      failPlayOnce = false;
      throw StateError('play failed');
    }
  }

  @override
  Future<void> pause() async {
    pauses++;
    if (!pauseStarted.isCompleted) pauseStarted.complete();
    if (holdPause) await pauseRelease.future;
    if (failPause) throw StateError('late pause failure');
    value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> dispose() async {
    disposals++;
    if (failDispose) {
      failDispose = false;
      throw StateError('dispose failed');
    }
    await super.dispose();
  }
}

Widget _page(Future<VideoRendition> Function() load, _HeldPlayer player) =>
    CupertinoApp(
        home: GalleryVideoPreviewPage(
            loadRendition: load,
            thumbnailBytes: Uint8List(0),
            duration: null,
            selected: false,
            onToggle: () {},
            controllerFactory: (_) => player));

Future<void> _disposeGallery(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  expect(SharedVideoPlayback.arbiter.debugHasCurrent, isFalse);
  expect(SharedVideoPlayback.arbiter.debugHasPendingBarrier, isFalse);
  expect(SharedVideoPlayback.arbiter.debugHasRetryPause, isFalse);
}

final class _OwnedFile extends Fake implements File {
  _OwnedFile(this.path);

  @override
  final String path;
  var existsValue = true;
  var deleteCalls = 0;

  @override
  Future<bool> exists() async => existsValue;

  @override
  Future<File> delete({bool recursive = false}) async {
    deleteCalls++;
    existsValue = false;
    return this;
  }
}

void main() {
  late bool previousHitTestWarning;
  setUp(() {
    previousHitTestWarning = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
  });

  tearDown(() {
    WidgetController.hitTestWarningShouldBeFatal = previousHitTestWarning;
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets('background completion never starts gallery playback',
      (tester) async {
    final rendition = Completer<VideoRendition>();
    final player = _HeldPlayer();
    final file = _OwnedFile('background-rendition.mp4');
    await tester.pumpWidget(_page(() => rendition.future, player));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    rendition.complete(VideoRendition(file: file, usedCompressed: true));
    player.initialized.complete();
    await tester.pumpAndSettle();
    expect(player.plays, 0);
    await _disposeGallery(tester);
  });

  testWidgets('late rendition after disposal releases its owned file',
      (tester) async {
    final rendition = Completer<VideoRendition>();
    final player = _HeldPlayer();
    await tester.pumpWidget(_page(() => rendition.future, player));
    await tester.pumpWidget(const SizedBox());
    final file = _OwnedFile('late-rendition.mp4');
    rendition.complete(VideoRendition(file: file, usedCompressed: true));
    await tester.pump();
    await tester.pump();
    expect(file.deleteCalls, 1);
  });

  testWidgets('held gallery play completed in background is paused',
      (tester) async {
    final rendition = Completer<VideoRendition>();
    final player = _HeldPlayer(holdPlay: true);
    player.initialized.complete();
    await tester.pumpWidget(_page(() => rendition.future, player));
    rendition.complete(
        VideoRendition(file: _OwnedFile('held.mp4'), usedCompressed: true));
    await tester.pump();
    await player.playStarted.future;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    player.playRelease.complete();
    await tester.pumpAndSettle();
    expect(player.value.isPlaying, isFalse);
    expect(player.pauses, greaterThanOrEqualTo(1));
    await tester.pumpWidget(const SizedBox());
    expect(SharedVideoPlayback.arbiter.debugHasCurrent, isFalse);
    expect(SharedVideoPlayback.arbiter.debugHasPendingBarrier, isFalse);
    expect(SharedVideoPlayback.arbiter.debugHasRetryPause, isFalse);
  });

  testWidgets('latest retry generation retains its rendition', (tester) async {
    final second = Completer<VideoRendition>();
    var calls = 0;
    final player = _HeldPlayer();
    player.initialized.complete();
    Future<VideoRendition> load() {
      calls++;
      return switch (calls) {
        1 => Future<VideoRendition>.error(StateError('initial failure')),
        2 => second.future,
        _ => second.future,
      };
    }

    await tester.pumpWidget(_page(load, player));
    await tester.pumpAndSettle();
    final retry = tester.widget<CupertinoButton>(
      find.byKey(const Key('gallery-video-retry')),
    );
    retry.onPressed!();
    retry.onPressed!();
    await tester.pump();
    final current = _OwnedFile('current.mp4');
    expect(calls, 2, reason: 'concurrent retry is coalesced');
    second.complete(VideoRendition(file: current, usedCompressed: true));
    await tester.pumpAndSettle();
    expect(current.deleteCalls, 0);
    await _disposeGallery(tester);
    expect(current.deleteCalls, 1);
  });

  testWidgets('double tap during held gallery play has one native play',
      (tester) async {
    final player = _HeldPlayer(holdPlay: true);
    player.initialized.complete();
    await tester.pumpWidget(_page(
        () async =>
            VideoRendition(file: _OwnedFile('tap.mp4'), usedCompressed: true),
        player));
    await player.playStarted.future;
    await tester.pump();
    await tester.tap(find.ancestor(
        of: find.byType(VideoPlayer), matching: find.byType(GestureDetector)));
    await tester.tap(find.ancestor(
        of: find.byType(VideoPlayer), matching: find.byType(GestureDetector)));
    await tester.pump();
    expect(player.plays, 1);
    player.playRelease.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'disposed gallery owner late pause error does not block next owner',
      (tester) async {
    final first = _HeldPlayer(holdPause: true);
    final second = _HeldPlayer();
    first.initialized.complete();
    second.initialized.complete();
    Widget page(bool a, bool b) => CupertinoApp(
            home: Stack(children: [
          if (a)
            GalleryVideoPreviewPage(
                key: const ValueKey('A'),
                loadRendition: () async => VideoRendition(
                    file: _OwnedFile('a.mp4'), usedCompressed: true),
                thumbnailBytes: Uint8List(0),
                duration: null,
                selected: false,
                onToggle: () {},
                controllerFactory: (_) => first),
          if (b)
            GalleryVideoPreviewPage(
                key: const ValueKey('B'),
                loadRendition: () async => VideoRendition(
                    file: _OwnedFile('b.mp4'), usedCompressed: true),
                thumbnailBytes: Uint8List(0),
                duration: null,
                selected: false,
                onToggle: () {},
                controllerFactory: (_) => second),
        ]));
    await tester.pumpWidget(page(true, false));
    await tester.pumpAndSettle();
    await tester.pumpWidget(page(true, true));
    await first.pauseStarted.future;
    await tester.pumpWidget(page(false, true));
    await tester.pump();
    expect(first.disposals, greaterThanOrEqualTo(1));
    first.failPause = true;
    first.pauseRelease.complete();
    await tester.pumpAndSettle();
    expect(second.value.isPlaying, isTrue);
  });

  testWidgets('failed disposal keeps retiring owner until pause succeeds',
      (tester) async {
    final first = _HeldPlayer(failDispose: true, failPause: true);
    final second = _HeldPlayer();
    first.initialized.complete();
    second.initialized.complete();
    Widget page(bool a, bool b) => CupertinoApp(
            home: Stack(children: [
          if (a)
            GalleryVideoPreviewPage(
                key: const ValueKey('A'),
                loadRendition: () async => VideoRendition(
                    file: _OwnedFile('a.mp4'), usedCompressed: true),
                thumbnailBytes: Uint8List(0),
                duration: null,
                selected: false,
                onToggle: () {},
                controllerFactory: (_) => first),
          if (b)
            GalleryVideoPreviewPage(
                key: const ValueKey('B'),
                loadRendition: () async => VideoRendition(
                    file: _OwnedFile('b.mp4'), usedCompressed: true),
                thumbnailBytes: Uint8List(0),
                duration: null,
                selected: false,
                onToggle: () {},
                controllerFactory: (_) => second),
        ]));
    await tester.pumpWidget(page(true, false));
    await tester.pumpAndSettle();
    await tester.pumpWidget(page(false, false));
    await tester.pumpAndSettle();
    final disposeError = tester.takeException();
    expect(disposeError, isA<StateError>());
    expect((disposeError! as StateError).message, 'dispose failed');
    await tester.pumpWidget(page(false, true));
    await tester.pump();
    expect(second.plays, 0);
    first.failPause = false;
    await tester.tap(find.byKey(const Key('gallery-video-retry')));
    await tester.pumpAndSettle();
    expect(second.value.isPlaying, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(SharedVideoPlayback.arbiter.debugHasCurrent, isFalse);
    expect(SharedVideoPlayback.arbiter.debugHasPendingBarrier, isFalse);
    expect(SharedVideoPlayback.arbiter.debugHasRetryPause, isFalse);
  });

  testWidgets('manual gallery pause remains paused across cover and lifecycle',
      (tester) async {
    final player = _HeldPlayer();
    player.initialized.complete();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(CupertinoApp(
        navigatorKey: navigator,
        home: GalleryVideoPreviewPage(
            loadRendition: () async => VideoRendition(
                file: _OwnedFile('manual.mp4'), usedCompressed: true),
            thumbnailBytes: Uint8List(0),
            duration: null,
            selected: false,
            onToggle: () {},
            controllerFactory: (_) => player)));
    await tester.pumpAndSettle();
    await tester.tap(find.ancestor(
        of: find.byType(VideoPlayer), matching: find.byType(GestureDetector)));
    await tester.pump();
    expect(player.value.isPlaying, isFalse);
    navigator.currentState!
        .push(CupertinoPageRoute<void>(builder: (_) => const SizedBox()));
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(player.value.isPlaying, isFalse);
    await tester.tap(find.ancestor(
        of: find.byType(VideoPlayer), matching: find.byType(GestureDetector)));
    await tester.pumpAndSettle();
    expect(player.value.isPlaying, isTrue);
    await _disposeGallery(tester);
  });

  testWidgets('same gallery retry pauses retiring controller before B plays',
      (tester) async {
    final first = _HeldPlayer(failPlayOnce: true, failDispose: true);
    final second = _HeldPlayer();
    first.initialized.complete();
    second.initialized.complete();
    var loads = 0;
    await tester.pumpWidget(CupertinoApp(home: GalleryVideoPreviewPage(
      loadRendition: () async => VideoRendition(file: _OwnedFile('retry-${++loads}.mp4'), usedCompressed: true),
      thumbnailBytes: Uint8List(0), duration: null, selected: false, onToggle: () {},
      controllerFactory: (_) => loads == 1 ? first : second,
    )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isA<StateError>());
    await tester.tap(find.byKey(const Key('gallery-video-retry')));
    await tester.pumpAndSettle();
    expect(first.pauses, greaterThanOrEqualTo(1));
    expect(second.value.isPlaying, isTrue);
    await _disposeGallery(tester);
  });
}
