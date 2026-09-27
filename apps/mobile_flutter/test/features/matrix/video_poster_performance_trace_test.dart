import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/features/matrix/media_load_scheduler.dart';
import 'package:liuhetong_mobile/features/matrix/video_poster_pipeline.dart';
import 'package:liuhetong_mobile/features/matrix/video_poster_session_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final poster = Uint8List.fromList([1, 2, 3]);

  test('server poster and memory hit create bounded identity-free traces',
      () async {
    var nowUs = 0;
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => nowUs,
      onRecord: records.add,
    );
    final pipeline = VideoPosterPipeline(
      accountId: 'private-user-id',
      roomId: 'private-room-id',
      memory: VideoPosterSessionCache(),
      loadServerPoster: (_) async {
        nowUs = 230000;
        return poster;
      },
      readCachedPoster: (_) async => null,
      writeCachedPoster: (_, __) async {},
      findLocalVideoFile: (_) async => null,
      performanceRecorder: recorder,
    );

    final first = await pipeline.resolve('private-media-uri');
    expect(first.source, VideoPosterSource.server);
    expect(records, hasLength(1));
    expect(records.single.operation, PerformanceOperationType.videoPoster);
    expect(records.single.totalMs, 230);
    expect(records.single.mediaType, PerformanceMediaType.video);
    expect(records.single.cacheSource, PerformanceCacheSource.serverPoster);
    expect(records.single.stagesUs,
        isNot(contains(PerformanceStage.downloadStarted)));
    final encoded = jsonEncode(records.single.toJson());
    for (final secret in [
      'private-user-id',
      'private-room-id',
      'private-media-uri',
    ]) {
      expect(encoded, isNot(contains(secret)));
    }

    nowUs = 300000;
    final second = await pipeline.resolve('private-media-uri');
    expect(second.source, VideoPosterSource.memory);
    expect(records, hasLength(2));
    expect(records.last.cacheSource, PerformanceCacheSource.memory);
    expect(recorder.activeCount, 0);
  });

  test('persistent disk lookup measures only its real read interval', () async {
    var nowUs = 0;
    final records = <PerformanceRecord>[];
    final pipeline = VideoPosterPipeline(
      accountId: 'account',
      roomId: 'room',
      memory: VideoPosterSessionCache(),
      loadServerPoster: (_) async {
        nowUs = 300000;
        return null;
      },
      readCachedPoster: (_) async {
        nowUs = 430000;
        return poster;
      },
      writeCachedPoster: (_, __) async {},
      findLocalVideoFile: (_) async => null,
      performanceRecorder: PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true),
        clockUs: () => nowUs,
        onRecord: records.add,
      ),
    );

    final outcome = await pipeline.resolve('disk-id');
    expect(outcome.source, VideoPosterSource.disk);
    expect(records.single.cacheSource, PerformanceCacheSource.disk);
    expect(
      records.single.betweenMs(
          PerformanceStage.cacheLoadStarted, PerformanceStage.cacheLoadDone),
      130,
    );
  });

  test('local frame trace reuses scheduler queue marks without video download',
      () async {
    final gate = Completer<Uint8List>();
    final blocker = mediaLoadScheduler
        .request('poster-trace-blocker', () => gate.future, isVideo: true);
    await Future<void>.delayed(Duration.zero);
    expect(mediaLoadScheduler.videoActiveCount, 1);

    var nowUs = 0;
    final records = <PerformanceRecord>[];
    final pipeline = VideoPosterPipeline(
      accountId: 'account',
      roomId: 'room',
      memory: VideoPosterSessionCache(),
      loadServerPoster: (_) async => null,
      readCachedPoster: (_) async => null,
      writeCachedPoster: (_, __) async {},
      findLocalVideoFile: (_) async => File('local-video.mp4'),
      extract: (_, __) async => poster,
      performanceRecorder: PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true),
        clockUs: () => nowUs,
        onRecord: records.add,
      ),
    );

    final pending = pipeline.resolve('poster-id');
    for (var i = 0; i < 10 && mediaLoadScheduler.queuedCount == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(mediaLoadScheduler.queuedCount, 1);
    nowUs = 1500000;
    gate.complete(poster);
    await blocker.value;
    final outcome = await pending;
    expect(outcome.source, VideoPosterSource.localFrame);
    expect(records.single.cacheSource, PerformanceCacheSource.localFrame);
    expect(
      records.single.betweenMs(
          PerformanceStage.queueEntered, PerformanceStage.queueExited),
      1500,
    );
    expect(records.single.stagesUs,
        isNot(contains(PerformanceStage.downloadStarted)));
  });

  test('caller-owned trace keeps its ID and remains open after resolve',
      () async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    );
    final trace = recorder.start(PerformanceOperationType.mediaLoad);
    final pipeline = VideoPosterPipeline(
      accountId: 'account',
      roomId: 'room',
      memory: VideoPosterSessionCache(),
      loadServerPoster: (_) async => poster,
      readCachedPoster: (_) async => null,
      writeCachedPoster: (_, __) async {},
      findLocalVideoFile: (_) async => null,
      performanceRecorder: recorder,
    );

    await pipeline.resolve('poster-id', trace: trace);
    expect(trace.isFinished, isFalse);
    expect(records, isEmpty);
    trace.finish();
    expect(records, hasLength(1));
    expect(records.single.operationId, trace.operationId);
  });

  test('a cancelled queued poster finishes its owned trace once', () async {
    final gate = Completer<Uint8List>();
    final blocker = mediaLoadScheduler
        .request('poster-cancel-blocker', () => gate.future, isVideo: true);
    final blocked =
        expectLater(blocker.value, throwsA(isA<MediaLoadCanceled>()));
    await Future<void>.delayed(Duration.zero);

    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    );
    final pipeline = VideoPosterPipeline(
      accountId: 'account',
      roomId: 'room',
      memory: VideoPosterSessionCache(),
      loadServerPoster: (_) async => null,
      readCachedPoster: (_) async => null,
      writeCachedPoster: (_, __) async {},
      findLocalVideoFile: (_) async => File('local-video.mp4'),
      extract: (_, __) async => poster,
      performanceRecorder: recorder,
    );
    final pending = pipeline.resolve('poster-cancel');
    for (var i = 0; i < 10 && mediaLoadScheduler.queuedCount == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(mediaLoadScheduler.queuedCount, 1);
    mediaLoadScheduler.cancelAll();
    await blocked;
    final outcome = await pending;
    expect(outcome.source, VideoPosterSource.placeholder);
    expect(records, hasLength(1));
    expect(records.single.result, PerformanceResult.cancelled);
    expect(recorder.activeCount, 0);
    gate.complete(poster);
  });
}
