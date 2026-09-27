import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:liuhetong_mobile/core/app_connection_status.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/features/matrix/gallery_video_preview.dart';
import 'package:liuhetong_mobile/features/matrix/device_gallery_source.dart';
import 'package:liuhetong_mobile/features/matrix/image_picker_page.dart';
import 'package:liuhetong_mobile/features/matrix/video_transcode.dart';
import 'package:liuhetong_mobile/ui/chat/shared_video_playback.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_video_message.dart';
import 'package:liuhetong_mobile/ui/components/network_status_capsule.dart';
import 'package:video_player/video_player.dart';

final class _File extends Fake implements File {
  _File(this.path, {this.present = true});
  @override
  final String path;
  bool present;
  var deletes = 0;
  @override
  Future<bool> exists() async => present;
  @override
  Future<int> length() async => 3;
  @override
  Future<File> delete({bool recursive = false}) async {
    deletes++;
    present = false;
    return this;
  }
}

final class _Player extends VideoPlayerController {
  _Player({this.failInitialize = false, this.initializeGate})
      : super.file(File('unused'));
  bool failInitialize;
  final Future<void>? initializeGate;
  var initializes = 0;
  var disposals = 0;
  var plays = 0;
  @override
  Future<void> initialize() async {
    initializes++;
    await initializeGate;
    if (failInitialize) throw StateError('synthetic decode failure');
    value = value.copyWith(isInitialized: true, size: const Size(10, 10));
  }

  @override
  Future<void> play() async {
    plays++;
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> pause() async => value = value.copyWith(isPlaying: false);
  @override
  Future<void> dispose() async {
    disposals++;
    await super.dispose();
  }
}

final class _Pager extends DeviceGalleryPager {
  _Pager(this.photo);
  final GalleryPhoto photo;
  bool served = false;
  @override
  bool get hasMore => !served;
  @override
  Future<List<GalleryPhoto>> loadNextPage({int pageSize = 20}) async {
    if (served) return [];
    served = true;
    return [photo];
  }
}

Widget _page(
        Future<File?> Function() original,
        Future<VideoRendition> Function() fallback,
        VideoPlayerController Function(File) factory) =>
    CupertinoApp(
        home: GalleryVideoPreviewPage(
            loadOriginalFile: original,
            loadRendition: fallback,
            controllerFactory: factory,
            thumbnailBytes: Uint8List(0),
            duration: null,
            selected: false,
            onToggle: () {}));

Future<void> _remove(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  expect(SharedVideoPlayback.arbiter.debugHasCurrent, isFalse);
  expect(SharedVideoPlayback.arbiter.debugHasPendingBarrier, isFalse);
  expect(SharedVideoPlayback.arbiter.debugHasRetryPause, isFalse);
}

void main() {
  testWidgets('picker routes borrowed source and traced fallback independently',
      (tester) async {
    final held = Completer<File?>();
    Future<File?> original() => held.future;
    Future<VideoRendition> fallback() async =>
        throw const VideoCompressionException();
    Future<VideoRendition> traced(
            PerformanceTrace? trace, void Function(double)? progress) =>
        fallback();
    final photo = GalleryPhoto(
        id: 'synthetic-video',
        thumbnail: Uint8List(0),
        compressedBytes: () async => Uint8List(0),
        originalBytes: () async => Uint8List(0),
        isVideo: true,
        localVideoFile: original,
        compressedPreviewFile: fallback,
        tracedCompressedPreviewFile: traced);
    const channel = MethodChannel('com.fluttercandies/photo_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    GalleryAccessCache.invalidateAll();
    messenger.setMockMethodCallHandler(channel, (_) async => 1);
    try {
      await tester.pumpWidget(CupertinoApp(
          home: ImagePickerPage(pagerBuilder: () => _Pager(photo))));
      await tester.pump();
      await tester.pump();
      final rect = tester
          .getRect(find.byKey(const Key('image-picker-item-synthetic-video')));
      await tester.tapAt(Offset(rect.right - 8, rect.center.dy));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final page = tester.widget<GalleryVideoPreviewPage>(
          find.byType(GalleryVideoPreviewPage));
      expect(page.loadOriginalFile, same(original));
      expect(page.loadRendition, same(fallback));
      expect(page.loadTracedRendition, same(traced));
      await _remove(tester);
      held.complete(null);
      await tester.pump();
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
      GalleryAccessCache.invalidateAll();
    }
  });

  testWidgets('playable original previews without invoking a failing encoder',
      (tester) async {
    final original = _File('borrowed.mp4');
    final player = _Player();
    var fallbackCalls = 0;
    await tester.pumpWidget(_page(() async => original, () async {
      fallbackCalls++;
      throw const VideoCompressionException();
    }, (file) {
      expect(file, same(original));
      return player;
    }));
    await tester.pumpAndSettle();
    expect(player.plays, 1);
    expect(fallbackCalls, 0);
    expect(find.byKey(const Key('gallery-video-retry')), findsNothing);
    await _remove(tester);
    expect(original.deletes, 0);
    expect(player.disposals, 1);
  });

  testWidgets('unsupported original decode falls back and owns only output',
      (tester) async {
    final original = _File('borrowed.mov');
    final output = _File('derived.mp4');
    final decoder = _Player(failInitialize: true);
    final fallbackPlayer = _Player();
    var fallbackCalls = 0;
    await tester.pumpWidget(_page(() async => original, () async {
      fallbackCalls++;
      expect(decoder.disposals, 1);
      return VideoRendition(file: output, usedCompressed: true);
    }, (file) => identical(file, original) ? decoder : fallbackPlayer));
    await tester.pumpAndSettle();
    expect(decoder.initializes, 1);
    expect(fallbackCalls, 1);
    expect(fallbackPlayer.plays, 1);
    await _remove(tester);
    expect(original.deletes, 0);
    expect(output.deletes, 1);
  });

  testWidgets(
      'missing original uses fallback without initializing missing file',
      (tester) async {
    final original = _File('missing.mp4', present: false);
    final output = _File('derived.mp4');
    final player = _Player();
    await tester.pumpWidget(_page(() async => original,
        () async => VideoRendition(file: output, usedCompressed: true), (file) {
      expect(file, same(output));
      return player;
    }));
    await tester.pumpAndSettle();
    expect(player.plays, 1);
    await _remove(tester);
    expect(original.deletes, 0);
    expect(output.deletes, 1);
  });

  testWidgets('late borrowed original never starts decoding or fallback',
      (tester) async {
    final source = Completer<File?>();
    final original = _File('borrowed.mp4');
    var fallbackCalls = 0, controllers = 0;
    await tester.pumpWidget(_page(() => source.future, () async {
      fallbackCalls++;
      throw const VideoCompressionException();
    }, (_) {
      controllers++;
      return _Player();
    }));
    await _remove(tester);
    source.complete(original);
    await tester.pump();
    expect(fallbackCalls, 0);
    expect(controllers, 0);
    expect(original.deletes, 0);
  });

  testWidgets(
      'late original decode failure never begins fallback after removal',
      (tester) async {
    final gate = Completer<void>();
    final original = _File('borrowed.mov');
    final player = _Player(failInitialize: true, initializeGate: gate.future);
    var fallbackCalls = 0;
    await tester.pumpWidget(_page(() async => original, () async {
      fallbackCalls++;
      throw const VideoCompressionException();
    }, (_) => player));
    await tester.pump();
    await _remove(tester);
    gate.complete();
    await tester.pump();
    expect(player.disposals, 1);
    expect(fallbackCalls, 0);
    expect(original.deletes, 0);
  });

  testWidgets('late fallback completion releases owned output after removal',
      (tester) async {
    final output = _File('derived.mp4');
    final fallback = Completer<VideoRendition>();
    var controllers = 0;
    await tester.pumpWidget(_page(() async => null, () => fallback.future, (_) {
      controllers++;
      return _Player();
    }));
    await tester.pump();
    await _remove(tester);
    fallback.complete(VideoRendition(file: output, usedCompressed: true));
    await tester.pump();
    expect(controllers, 0);
    expect(output.deletes, 1);
  });

  testWidgets(
      'retry starts again with original and does not retain failed output',
      (tester) async {
    final original = _File('borrowed.mov');
    final output = _File('derived.mp4');
    var originalDecodes = 0, fallbackCalls = 0;
    final players = <_Player>[];
    await tester.pumpWidget(_page(() async => original, () async {
      fallbackCalls++;
      return VideoRendition(file: output, usedCompressed: true);
    }, (file) {
      final fail = identical(file, original) ? originalDecodes++ == 0 : true;
      final player = _Player(failInitialize: fail);
      players.add(player);
      return player;
    }));
    await tester.pumpAndSettle();
    expect(output.deletes, 1);
    await tester.tap(find.byKey(const Key('gallery-video-retry')));
    await tester.pumpAndSettle();
    expect(originalDecodes, 2);
    expect(fallbackCalls, 1);
    expect(players.last.plays, 1);
    await _remove(tester);
    expect(original.deletes, 0);
  });

  for (final gallery in [true, false]) {
    testWidgets(
        '${gallery ? 'gallery and moments' : 'room'} loading is inline without network capsule',
        (tester) async {
      final owner = Object();
      final connection = ValueNotifier(AppConnectionStatus.connecting);
      final hub = AppConnectionStatusHub.shared;
      hub.bind(owner, connection, (value) => value);
      try {
        await tester.pumpWidget(CupertinoApp(
            home: gallery
                ? GalleryVideoPreviewPage(
                    viewerOnly: true,
                    loadRendition: () => Completer<VideoRendition>().future,
                    thumbnailBytes: Uint8List(0),
                    duration: null,
                    selected: false,
                    onToggle: () {})
                : VideoViewerPage(loadFile: () => Completer<File>().future)));
        expect(find.byType(WeChatNetworkStatusCapsule), findsNothing);
        expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
        connection.value = AppConnectionStatus.offline;
        await tester.pump();
        expect(find.byKey(const Key('network-status-capsule')), findsNothing);
        if (!gallery) {
          await tester.pump(const Duration(seconds: 121));
          await tester.pump();
          expect(find.byKey(const Key('video-viewer-retry')), findsOneWidget);
        }
        await _remove(tester);
      } finally {
        hub.unbind(owner);
        connection.dispose();
      }
    });
  }

  for (final pendingStage in ['original', 'decode', 'fallback']) {
    testWidgets('exit closes pending $pendingStage trace before late cleanup',
        (tester) async {
      final original = _File('private-borrowed.mp4');
      final output = _File('private-derived.mp4');
      final originalGate = Completer<File?>();
      final decodeGate = Completer<void>();
      final fallbackGate = Completer<VideoRendition>();
      final player = _Player(
          initializeGate: pendingStage == 'decode' ? decodeGate.future : null);
      final records = <PerformanceRecord>[];
      final recorder = PerformanceTraceRecorder(
          metrics: PerformanceMetrics(enabled: true), onRecord: records.add);
      var fallbackCalls = 0, controllers = 0;
      await tester.pumpWidget(CupertinoApp(
          home: GalleryVideoPreviewPage(
              loadOriginalFile: () => pendingStage == 'original'
                  ? originalGate.future
                  : Future.value(pendingStage == 'decode' ? original : null),
              loadRendition: () {
                fallbackCalls++;
                return fallbackGate.future;
              },
              traceFactory: () =>
                  recorder.start(PerformanceOperationType.videoPrepare),
              thumbnailBytes: Uint8List(0),
              duration: null,
              selected: false,
              onToggle: () {},
              controllerFactory: (_) {
                controllers++;
                return player;
              })));
      await tester.pump();
      expect(recorder.activeCount, 1);
      try {
        await _remove(tester);
        expect(recorder.activeCount, 0);
        expect(records, hasLength(1));
        expect(records.single.result, PerformanceResult.cancelled);
        expect(jsonEncode(records.single.toJson()), isNot(contains('private')));
      } finally {
        originalGate.complete(original);
        decodeGate.complete();
        fallbackGate
            .complete(VideoRendition(file: output, usedCompressed: true));
        await tester.pump();
      }
      expect(records, hasLength(1));
      expect(original.deletes, 0);
      expect(output.deletes, pendingStage == 'fallback' ? 1 : 0);
      expect(fallbackCalls, pendingStage == 'fallback' ? 1 : 0);
      expect(controllers, pendingStage == 'decode' ? 1 : 0);
      expect(player.plays, 0);
      expect(player.disposals, pendingStage == 'decode' ? 1 : 0);
    });
  }

  testWidgets('borrowed preview records closed preparation without encoding',
      (tester) async {
    final original = _File('borrowed-private.mp4');
    final player = _Player();
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true), onRecord: records.add);
    await tester.pumpWidget(CupertinoApp(
        home: GalleryVideoPreviewPage(
            loadOriginalFile: () async => original,
            loadRendition: () async => throw const VideoCompressionException(),
            traceFactory: () =>
                recorder.start(PerformanceOperationType.videoPrepare),
            thumbnailBytes: Uint8List(0),
            duration: null,
            selected: false,
            onToggle: () {},
            controllerFactory: (_) => player)));
    await tester.pumpAndSettle();
    expect(records, hasLength(1));
    expect(records.single.result, PerformanceResult.success);
    expect(
        records.single.stagesUs.keys,
        containsAll([
          PerformanceStage.videoPrepareStarted,
          PerformanceStage.decodeStarted,
          PerformanceStage.decodeDone,
          PerformanceStage.videoPrepareDone,
        ]));
    expect(jsonEncode(records.single.toJson()), isNot(contains(original.path)));
    expect(recorder.activeCount, 0);
    await _remove(tester);
  });

  testWidgets(
      'preview fallback retains real native failure attempts without paths',
      (tester) async {
    final original = _File('private-original.mov');
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true), onRecord: records.add);
    var calls = 0;
    const channel = MethodChannel('video_compress');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getMediaInfo') {
        return jsonEncode({'path': original.path, 'duration': 1000});
      }
      if (call.method == 'compressVideo') {
        calls++;
        throw PlatformException(
            code: 'video_transcode_failed',
            message: 'private-original.mov private native content');
      }
      return null;
    });
    try {
      await tester.pumpWidget(CupertinoApp(
          home: GalleryVideoPreviewPage(
              loadOriginalFile: () async => null,
              loadRendition: () async =>
                  throw StateError('unused untraced callback'),
              loadTracedRendition: (trace, onProgress) => transcodeForChat(
                  original,
                  performanceTrace: trace,
                  onProgress: onProgress),
              traceFactory: () =>
                  recorder.start(PerformanceOperationType.videoPrepare),
              thumbnailBytes: Uint8List(0),
              duration: null,
              selected: false,
              onToggle: () {})));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(records, hasLength(1));
      expect(records.single.result, PerformanceResult.failed);
      final encoded = records.single.toLocalDiagnosticJson();
      expect((encoded['video_transcode_attempts'] as List), hasLength(2));
      expect(jsonEncode(encoded), contains('native_failure'));
      expect(jsonEncode(encoded), isNot(contains('private')));
      expect(recorder.activeCount, 0);
      expect(find.byKey(const Key('gallery-video-retry')), findsOneWidget);
      await _remove(tester);
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
