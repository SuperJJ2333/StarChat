import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/gallery_video_preview.dart';
import 'package:liuhetong_mobile/features/matrix/video_transcode.dart';
import 'package:liuhetong_mobile/ui/chat/shared_video_playback.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_video_message.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

final class _HeldPlayer extends VideoPlayerController {
  _HeldPlayer(
      {this.holdPlay = false,
      this.holdPause = false,
      this.throwOnPlay = false,
      this.failAtPlay,
      this.failAtPause})
      : super.file(File('unused'));

  final initialized = Completer<void>();
  final playStarted = Completer<void>();
  final playRelease = Completer<void>();
  final pauseStarted = Completer<void>();
  final pauseRelease = Completer<void>();
  bool holdPlay;
  bool holdPause;
  final bool throwOnPlay;
  final int? failAtPlay;
  final int? failAtPause;
  var plays = 0;
  var activePlays = 0;
  var peakActivePlays = 0;
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
    if (holdPlay) {
      activePlays++;
      peakActivePlays =
          peakActivePlays > activePlays ? peakActivePlays : activePlays;
      await playRelease.future;
      activePlays--;
    }
    if (throwOnPlay || failAtPlay == plays) throw StateError('play failed');
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> pause() async {
    pauses++;
    if (holdPause) {
      if (!pauseStarted.isCompleted) pauseStarted.complete();
      await pauseRelease.future;
    }
    if (failAtPause == pauses) throw StateError('pause failed');
    value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await super.dispose();
  }
}

final class _RecordingWakelock extends WakelockPlusPlatformInterface {
  final values = <bool>[];
  var _enabled = false;

  @override
  Future<void> toggle({required bool enable}) async {
    values.add(enable);
    _enabled = enable;
  }

  @override
  Future<bool> get enabled async => _enabled;
}

Widget _page(_HeldPlayer player) => CupertinoApp(
    home: VideoViewerPage(
        loadFile: () async => File('unused'),
        controllerFactory: (_) => player));

Future<void> _flushWakelock(WidgetTester tester) async {
  var settled = false;
  VideoViewerPage.debugWakelockSettled().then((_) => settled = true);
  for (var frame = 0; frame < 8 && !settled; frame++) {
    await tester.pump();
  }
  expect(settled, isTrue, reason: 'wakelock transition did not settle');
}

Future<void> _disposeWidgets(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await _flushWakelock(tester);
  expect(VideoViewerPage.debugArbiterState,
      (current: false, pending: false, retry: false));
}

void main() {
  late WakelockPlusPlatformInterface originalWakelock;
  late _RecordingWakelock wakelock;

  setUpAll(() {
    originalWakelock = wakelockPlusPlatformInstance;
    wakelock = _RecordingWakelock();
    wakelockPlusPlatformInstance = wakelock;
  });

  setUp(() async {
    wakelock.values.clear();
    await WakelockPlus.toggle(enable: false);
    expect(wakelock.values, [false]);
    wakelock.values.clear();
    TestWidgetsFlutterBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  tearDownAll(() {
    wakelockPlusPlatformInstance = originalWakelock;
  });

  testWidgets(
      'held play completed in background is paused and releases wakelock',
      (tester) async {
    final player = _HeldPlayer(holdPlay: true);
    player.initialized.complete();
    await tester.pumpWidget(_page(player));
    await tester.pump();
    await player.playStarted.future;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    player.playRelease.complete();
    await tester.pumpAndSettle();

    expect(player.value.isPlaying, isFalse);
    expect(player.pauses, greaterThanOrEqualTo(1));
    await _flushWakelock(tester);
    expect(wakelock.values.last, isFalse);
    await _disposeWidgets(tester);
  });

  testWidgets('held initialization completed in background never plays',
      (tester) async {
    final player = _HeldPlayer();
    await tester.pumpWidget(_page(player));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    player.initialized.complete();
    await tester.pumpAndSettle();
    expect(player.plays, 0);
    await _disposeWidgets(tester);
  });

  testWidgets('late first viewer cannot replace a newer viewer wakelock owner',
      (tester) async {
    final first = _HeldPlayer(holdPlay: true);
    final second = _HeldPlayer();
    first.initialized.complete();
    second.initialized.complete();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(CupertinoApp(
        navigatorKey: navigator,
        home: VideoViewerPage(
            loadFile: () async => File('first'),
            controllerFactory: (_) => first)));
    await tester.pump(const Duration(milliseconds: 500));
    await first.playStarted.future;

    unawaited(navigator.currentState!.push(CupertinoPageRoute<void>(
        builder: (_) => VideoViewerPage(
            loadFile: () async => File('second'),
            controllerFactory: (_) => second))));
    await tester.pumpAndSettle();
    expect(second.value.isPlaying, isTrue);

    first.playRelease.complete();
    await tester.pumpAndSettle();
    expect(first.value.isPlaying, isFalse);
    expect(second.value.isPlaying, isTrue);
    await _flushWakelock(tester);
    expect(wakelock.values.last, isTrue);
    await _disposeWidgets(tester);
  });

  testWidgets('disposing old route cannot cancel newer held playback',
      (tester) async {
    final first = _HeldPlayer();
    final second = _HeldPlayer(holdPlay: true);
    first.initialized.complete();
    second.initialized.complete();
    final navigator = GlobalKey<NavigatorState>();
    late Route<void> firstRoute;
    await tester.pumpWidget(CupertinoApp(
        navigatorKey: navigator,
        onGenerateRoute: (_) =>
            CupertinoPageRoute<void>(builder: (_) => const SizedBox()),
        onGenerateInitialRoutes: (_) {
          firstRoute = CupertinoPageRoute<void>(
              builder: (_) => VideoViewerPage(
                  loadFile: () async => File('first'),
                  controllerFactory: (_) => first));
          return [firstRoute];
        }));
    await tester.pumpAndSettle();
    unawaited(navigator.currentState!.push(CupertinoPageRoute<void>(
        builder: (_) => VideoViewerPage(
            loadFile: () async => File('second'),
            controllerFactory: (_) => second))));
    await tester.pump();
    await second.playStarted.future;
    navigator.currentState!.removeRoute(firstRoute);
    second.playRelease.complete();
    await tester.pumpAndSettle();
    await _flushWakelock(tester);
    expect(second.value.isPlaying, isTrue);
    expect(wakelock.values.last, isTrue);
    await _disposeWidgets(tester);
  });

  testWidgets('held initialization after dispose never plays and disposes',
      (tester) async {
    final player = _HeldPlayer();
    await tester.pumpWidget(_page(player));
    await tester.pumpWidget(const SizedBox());
    player.initialized.complete();
    await tester.pumpAndSettle();

    expect(player.plays, 0);
    expect(player.disposals, greaterThan(0));
    await _disposeWidgets(tester);
  });

  testWidgets('failed initialization retries with a new controller only',
      (tester) async {
    final failed = _HeldPlayer();
    final replacement = _HeldPlayer();
    var created = 0;
    await tester.pumpWidget(CupertinoApp(
        home: VideoViewerPage(
            loadFile: () async => File('unused'),
            controllerFactory: (_) => created++ == 0 ? failed : replacement)));
    failed.initialized.completeError(StateError('initialize failed'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('video-viewer-retry')), findsOneWidget);
    expect(failed.plays, 0);
    expect(failed.disposals, 1);
    await tester.tap(find.byKey(const Key('video-viewer-retry')));
    replacement.initialized.complete();
    await tester.pumpAndSettle();
    expect(replacement.plays, 1);
    expect(replacement.value.isPlaying, isTrue);
    expect(failed.plays, 0);
    expect(failed.disposals, 1);
    await _disposeWidgets(tester);
  });

  testWidgets(
      'manual pause disables wakelock and does not resume after foreground',
      (tester) async {
    final player = _HeldPlayer();
    player.initialized.complete();
    await tester.pumpWidget(_page(player));
    await tester.pumpAndSettle();
    await _flushWakelock(tester);
    expect(wakelock.values.last, isTrue);

    await tester.tap(find.byIcon(CupertinoIcons.pause_circle));
    await tester.pumpAndSettle();
    expect(player.value.isPlaying, isFalse);
    await _flushWakelock(tester);
    expect(wakelock.values.last, isFalse);
    final plays = player.plays;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(player.plays, plays);
    await _disposeWidgets(tester);
  });

  testWidgets('covered route pauses and manual pause does not resume on return',
      (tester) async {
    final player = _HeldPlayer();
    player.initialized.complete();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(CupertinoApp(
        navigatorKey: navigator,
        home: VideoViewerPage(
            loadFile: () async => File('unused'),
            controllerFactory: (_) => player)));
    await tester.pumpAndSettle();
    final beforeCover = player.pauses;
    unawaited(navigator.currentState!.push(CupertinoPageRoute<void>(
        builder: (_) => const ColoredBox(color: CupertinoColors.black))));
    await tester.pumpAndSettle();
    expect(player.pauses, greaterThan(beforeCover));
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(player.plays, greaterThan(1));

    await tester.tap(find.byIcon(CupertinoIcons.pause_circle));
    await tester.pumpAndSettle();
    final plays = player.plays;
    unawaited(navigator.currentState!.push(CupertinoPageRoute<void>(
        builder: (_) => const ColoredBox(color: CupertinoColors.black))));
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(player.plays, plays);
    await _disposeWidgets(tester);
  });

  testWidgets('play failure releases wakelock and a retry can own it',
      (tester) async {
    final failing = _HeldPlayer(throwOnPlay: true);
    final replacement = _HeldPlayer();
    failing.initialized.complete();
    replacement.initialized.complete();
    var created = 0;
    await tester.pumpWidget(CupertinoApp(
        home: VideoViewerPage(
            loadFile: () async => File('unused'),
            controllerFactory: (_) => created++ == 0 ? failing : replacement)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('video-viewer-retry')), findsOneWidget);
    await _flushWakelock(tester);
    expect(wakelock.values.last, isFalse);

    await tester.tap(find.byKey(const Key('video-viewer-retry')));
    await tester.pumpAndSettle();
    expect(replacement.value.isPlaying, isTrue);
    await _flushWakelock(tester);
    expect(wakelock.values.last, isTrue);
    await _disposeWidgets(tester);
  });

  testWidgets('manual resume play failure stays paused and releases wakelock',
      (tester) async {
    final player = _HeldPlayer(failAtPlay: 2);
    player.initialized.complete();
    await tester.pumpWidget(_page(player));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(CupertinoIcons.pause_circle));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.play_circle));
    await tester.pumpAndSettle();
    await _flushWakelock(tester);
    expect(player.value.isPlaying, isFalse);
    expect(find.text('视频播放失败，请重试'), findsOneWidget);
    expect(wakelock.values.last, isFalse);
    await _disposeWidgets(tester);
  });

  testWidgets('forward releases the playback lease before its callback',
      (tester) async {
    final player = _HeldPlayer();
    player.initialized.complete();
    final forwarded = Completer<void>();
    await tester.pumpWidget(CupertinoApp(
        home: VideoViewerPage(
            loadFile: () async => File('unused'),
            controllerFactory: (_) => player,
            onForward: () => forwarded.future)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('video-viewer-forward')));
    await tester.pump();
    await _flushWakelock(tester);
    expect(player.value.isPlaying, isFalse);
    expect(wakelock.values.last, isFalse);
    forwarded.complete();
    await tester.pumpAndSettle();
    await _disposeWidgets(tester);
  });

  testWidgets('stopped playback releases wakelock on the next ticker frame',
      (tester) async {
    final player = _HeldPlayer();
    player.initialized.complete();
    await tester.pumpWidget(_page(player));
    await tester.pumpAndSettle();
    player.value = player.value.copyWith(isPlaying: false);
    await tester.pump(const Duration(milliseconds: 300));
    await _flushWakelock(tester);
    expect(wakelock.values.last, isFalse);
    await _disposeWidgets(tester);
  });

  testWidgets('repeated resume while play is held has one native play',
      (tester) async {
    final player = _HeldPlayer();
    player.initialized.complete();
    await tester.pumpWidget(_page(player));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(CupertinoIcons.pause_circle));
    await tester.pumpAndSettle();

    player.holdPlay = true;
    await tester.tap(find.byIcon(CupertinoIcons.play_circle));
    await tester.pump();
    await player.playStarted.future;
    await tester.tap(find.byIcon(CupertinoIcons.play_circle));
    await tester.pump();
    expect(player.peakActivePlays, 1);
    player.playRelease.complete();
    await tester.pumpAndSettle();
    expect(player.value.isPlaying, isTrue);
    await _disposeWidgets(tester);
  });

  testWidgets('covered pending resume plays when its route returns',
      (tester) async {
    final player = _HeldPlayer();
    player.initialized.complete();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(CupertinoApp(
        navigatorKey: navigator,
        home: VideoViewerPage(
            loadFile: () async => File('unused'),
            controllerFactory: (_) => player)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(CupertinoIcons.pause_circle));
    await tester.pumpAndSettle();
    player.holdPlay = true;
    await tester.tap(find.byIcon(CupertinoIcons.play_circle));
    await tester.pump();
    unawaited(navigator.currentState!.push(CupertinoPageRoute<void>(
        builder: (_) => const ColoredBox(color: CupertinoColors.black))));
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    player.playRelease.complete();
    await tester.pumpAndSettle();
    expect(player.value.isPlaying, isTrue);
    expect(player.peakActivePlays, 1);
    await _disposeWidgets(tester);
  });

  testWidgets('next route waits for a held previous native pause',
      (tester) async {
    final first = _HeldPlayer(holdPause: true);
    final second = _HeldPlayer();
    first.initialized.complete();
    second.initialized.complete();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(CupertinoApp(
        navigatorKey: navigator,
        home: VideoViewerPage(
            loadFile: () async => File('first'), controllerFactory: (_) => first)));
    await tester.pumpAndSettle();
    unawaited(navigator.currentState!.push(CupertinoPageRoute<void>(
        builder: (_) => VideoViewerPage(
            loadFile: () async => File('second'), controllerFactory: (_) => second))));
    await tester.pump();
    await first.pauseStarted.future;
    expect(second.value.isInitialized, isTrue);
    expect(second.plays, 0);
    first.pauseRelease.complete();
    await tester.pumpAndSettle();
    expect(second.value.isPlaying, isTrue);
    await _disposeWidgets(tester);
  });

  testWidgets('returning to the same page waits for its held native pause',
      (tester) async {
    final player = _HeldPlayer(holdPause: true);
    player.initialized.complete();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(CupertinoApp(
        navigatorKey: navigator,
        home: VideoViewerPage(
            loadFile: () async => File('first'), controllerFactory: (_) => player)));
    await tester.pumpAndSettle();
    final plays = player.plays;
    unawaited(navigator.currentState!.push(CupertinoPageRoute<void>(
        builder: (_) => const SizedBox())));
    await tester.pump();
    await player.pauseStarted.future;
    navigator.currentState!.pop();
    await tester.pump();
    expect(player.plays, plays);
    player.pauseRelease.complete();
    await tester.pumpAndSettle();
    expect(player.plays, greaterThan(plays));
    await _disposeWidgets(tester);
  });

  testWidgets('next viewer retries a failed held previous native pause',
      (tester) async {
    final first = _HeldPlayer(holdPause: true, failAtPause: 1);
    final second = _HeldPlayer();
    first.initialized.complete();
    second.initialized.complete();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(CupertinoApp(
        navigatorKey: navigator,
        home: VideoViewerPage(
            loadFile: () async => File('first'), controllerFactory: (_) => first)));
    await tester.pumpAndSettle();
    unawaited(navigator.currentState!.push(CupertinoPageRoute<void>(
        builder: (_) => VideoViewerPage(
            loadFile: () async => File('second'), controllerFactory: (_) => second))));
    await tester.pump();
    await first.pauseStarted.future;
    expect(second.value.isInitialized, isTrue);
    expect(second.plays, 0);
    first.pauseRelease.complete();
    await tester.pumpAndSettle();
    expect(second.plays, 0);
    expect(find.byKey(const Key('video-viewer-retry')), findsOneWidget);
    await tester.tap(find.byKey(const Key('video-viewer-retry')));
    await tester.pumpAndSettle();
    expect(first.pauses, 2);
    expect(second.value.isPlaying, isTrue);
    await _disposeWidgets(tester);
  });

  testWidgets('viewer opened after a completed prior pause failure retries it',
      (tester) async {
    final first = _HeldPlayer(holdPause: true, failAtPause: 1);
    final second = _HeldPlayer();
    first.initialized.complete();
    second.initialized.complete();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(CupertinoApp(
        navigatorKey: navigator,
        home: VideoViewerPage(
            loadFile: () async => File('first'), controllerFactory: (_) => first)));
    await tester.pumpAndSettle();
    unawaited(navigator.currentState!.push(CupertinoPageRoute<void>(
        builder: (_) => const SizedBox())));
    await tester.pump();
    await first.pauseStarted.future;
    first.pauseRelease.complete();
    await tester.pumpAndSettle();

    unawaited(navigator.currentState!.push(CupertinoPageRoute<void>(
        builder: (_) => VideoViewerPage(
            loadFile: () async => File('second'), controllerFactory: (_) => second))));
    await tester.pumpAndSettle();
    expect(first.pauses, 2);
    expect(second.value.isPlaying, isTrue);
    await _disposeWidgets(tester);
  });

  testWidgets('disposed previous owner does not block waiting viewer after late pause error',
      (tester) async {
    final first = _HeldPlayer(holdPause: true, failAtPause: 1);
    final second = _HeldPlayer();
    first.initialized.complete();
    second.initialized.complete();
    Widget build(bool a, bool b) => CupertinoApp(home: Stack(children: [
          if (a)
            VideoViewerPage(
                key: const ValueKey('A'),
                loadFile: () async => File('a'),
                controllerFactory: (_) => first),
          if (b)
            VideoViewerPage(
                key: const ValueKey('B'),
                loadFile: () async => File('b'),
                controllerFactory: (_) => second),
        ]));
    await tester.pumpWidget(build(true, false));
    await tester.pumpAndSettle();
    await tester.pumpWidget(build(true, true));
    await tester.pump();
    expect(second.value.isInitialized, isTrue);
    expect(second.plays, 0);
    await first.pauseStarted.future;
    await tester.pumpWidget(build(false, true));
    await tester.pump();
    expect(first.disposals, greaterThanOrEqualTo(1));
    first.pauseRelease.complete();
    await tester.pumpAndSettle();
    expect(second.value.isPlaying, isTrue);
    await _disposeWidgets(tester);
  });
  testWidgets('gallery yields to viewer', (tester) async {
    final a = _HeldPlayer(), b = _HeldPlayer(); a.initialized.complete(); b.initialized.complete();
    Widget page(bool ga, bool vb) => CupertinoApp(home: Stack(children: [if (ga) GalleryVideoPreviewPage(key: const ValueKey('g'), loadRendition: () async => VideoRendition(file: File('g'), usedCompressed: false), thumbnailBytes: Uint8List(0), duration: null, selected: false, onToggle: () {}, controllerFactory: (_) => a), if (vb) VideoViewerPage(key: const ValueKey('v'), loadFile: () async => File('v'), controllerFactory: (_) => b)]));
    await tester.pumpWidget(page(true, false)); await tester.pumpAndSettle();
    await tester.pumpWidget(page(true, true)); await tester.pumpAndSettle();
    expect(a.pauses, greaterThanOrEqualTo(1)); expect(b.value.isPlaying, isTrue);
    await tester.pumpWidget(page(false, true)); await _flushWakelock(tester); expect(wakelock.values.last, isTrue);
    await _disposeWidgets(tester); expect(wakelock.values.last, isFalse);
  });
  testWidgets('viewer yields to gallery', (tester) async {
    final a = _HeldPlayer(), b = _HeldPlayer(); a.initialized.complete(); b.initialized.complete();
    Widget page(bool va, bool gb) => CupertinoApp(home: Stack(children: [if (va) VideoViewerPage(key: const ValueKey('v'), loadFile: () async => File('v'), controllerFactory: (_) => a), if (gb) GalleryVideoPreviewPage(key: const ValueKey('g'), loadRendition: () async => VideoRendition(file: File('g'), usedCompressed: false), thumbnailBytes: Uint8List(0), duration: null, selected: false, onToggle: () {}, controllerFactory: (_) => b)]));
    await tester.pumpWidget(page(true, false)); await tester.pumpAndSettle();
    await tester.pumpWidget(page(true, true)); await tester.pumpAndSettle();
    expect(b.value.isInitialized, isTrue);
    expect(b.plays, 1, reason: 'gallery did not reach native play');
    expect(SharedVideoPlayback.arbiter.debugHasCurrent, isTrue);
    expect(a.pauses, greaterThanOrEqualTo(1)); expect(b.value.isPlaying, isTrue);
    await tester.pumpWidget(page(false, true)); await _flushWakelock(tester); expect(wakelock.values.last, isTrue);
    expect(b.value.isPlaying, isTrue, reason: 'removing viewer paused gallery');
    await _disposeWidgets(tester); expect(wakelock.values.last, isFalse);
  });
}
