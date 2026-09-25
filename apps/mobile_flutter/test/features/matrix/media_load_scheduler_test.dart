import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/features/matrix/media_load_scheduler.dart';

void main() {
  test('a queued lease records actual wait and bounded scheduler state',
      () async {
    var nowUs = 0;
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => nowUs,
      onRecord: records.add,
    );
    final scheduler = MediaLoadScheduler(maxConcurrent: 1);
    final blocker = Completer<Uint8List>();
    final active = scheduler.request('active', () => blocker.future);
    await Future<void>.delayed(Duration.zero);

    final trace = recorder.start(PerformanceOperationType.mediaLoad);
    final queued = scheduler.request('queued', () async => Uint8List(1),
        priority: MediaLoadPriority.interactive, trace: trace);
    expect(scheduler.queuedCount, 1);
    expect(scheduler.activeCount, 1);
    expect(trace.schedulerQueue, 1);
    expect(trace.schedulerActive, 1);
    expect(trace.schedulerVideoActive, 0);
    expect(trace.mediaPriority, PerformanceMediaPriority.interactive);
    expect(trace.isFinished, isFalse);

    nowUs = 1800000;
    blocker.complete(Uint8List(1));
    await active.value;
    await queued.value;
    trace.finish();

    expect(records, hasLength(1));
    expect(
        records.single.betweenMs(
            PerformanceStage.queueEntered, PerformanceStage.queueExited),
        1800);
    expect(scheduler.queuedCount, 0);
    expect(scheduler.activeCount, 0);
    expect(scheduler.videoActiveCount, 0);
  });

  test('video queue trace captures active video slots and promoted priority',
      () async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    );
    final scheduler = MediaLoadScheduler(maxConcurrent: 1, maxVideos: 1);
    final blocker = Completer<Uint8List>();
    final first =
        scheduler.request('first-video', () => blocker.future, isVideo: true);
    await Future<void>.delayed(Duration.zero);
    expect(scheduler.videoActiveCount, 1);

    final trace = recorder.start(PerformanceOperationType.mediaLoad);
    final queued = scheduler.request(
      'second-video',
      () async => Uint8List(1),
      isVideo: true,
      priority: MediaLoadPriority.prefetch,
      trace: trace,
    );
    expect(trace.schedulerVideoActive, 1);
    expect(trace.mediaPriority, PerformanceMediaPriority.prefetch);
    scheduler.promote('second-video', MediaLoadPriority.interactive);

    blocker.complete(Uint8List(1));
    await first.value;
    await queued.value;
    trace.finish();
    expect(records.single.schedulerVideoActive, 1);
    expect(records.single.mediaPriority, PerformanceMediaPriority.interactive);
    expect(records.single.toJson()['scheduler_video_active'], 1);
    expect(records.single.toJson()['media_priority'], 'interactive');
  });

  test('active cancellation holds its slot and queued peers stay FIFO',
      () async {
    final scheduler = MediaLoadScheduler(maxConcurrent: 1);
    final gate = Completer<Uint8List>();
    final order = <String>[];
    final active = scheduler.request('active', () => gate.future);
    await Future<void>.delayed(Duration.zero);
    final peers = [
      for (final name in ['first', 'second'])
        scheduler.request(name, () async {
          order.add(name);
          return Uint8List(1);
        })
    ];
    final canceled =
        expectLater(active.value, throwsA(isA<MediaLoadCanceled>()));
    active.cancel();
    await canceled;
    await Future<void>.delayed(Duration.zero);
    expect(order, isEmpty);
    gate.complete(Uint8List(1));
    await Future.wait(peers.map((peer) => peer.value));
    expect(order, ['first', 'second']);
  });
  test('reentrant cancellation cannot start a stale queued snapshot', () async {
    final scheduler = MediaLoadScheduler(maxConcurrent: 2);
    late MediaLoadLease second;
    var secondStarted = false;
    final first = scheduler.request('first', () async {
      second.cancel();
      return Uint8List(1);
    });
    second = scheduler.request('second', () async {
      secondStarted = true;
      return Uint8List(1);
    });
    final canceled =
        expectLater(second.value, throwsA(isA<MediaLoadCanceled>()));
    await first.value;
    await canceled;
    expect(secondStarted, isFalse);
  });

  test('joining visible demand promotes an already queued prefetch', () async {
    final scheduler = MediaLoadScheduler(maxConcurrent: 1);
    final gate = Completer<Uint8List>();
    final order = <String>[];
    final active = scheduler.request('active', () => gate.future);
    await Future<void>.delayed(Duration.zero);
    final older = scheduler.request('older', () async {
      order.add('older');
      return Uint8List(1);
    });
    final prefetch = scheduler.request('prefetch', () async {
      order.add('prefetch');
      return Uint8List(1);
    }, priority: MediaLoadPriority.prefetch);
    scheduler.promote('prefetch', MediaLoadPriority.interactive);
    gate.complete(Uint8List(1));
    await Future.wait([active.value, older.value, prefetch.value]);
    expect(order, ['prefetch', 'older']);
  });

  test('interactive work overtakes prefetch and respects concurrency',
      () async {
    final scheduler = MediaLoadScheduler(maxConcurrent: 1);
    final gate = Completer<Uint8List>();
    final started = <String>[];
    final active = scheduler.request('active', () => gate.future);
    await Future<void>.delayed(Duration.zero);
    final prefetch = scheduler.request('prefetch', () async {
      started.add('prefetch');
      return Uint8List(1);
    }, priority: MediaLoadPriority.prefetch);
    final interactive = scheduler.request('tap', () async {
      started.add('tap');
      return Uint8List(1);
    }, priority: MediaLoadPriority.interactive);
    expect(started, isEmpty);
    gate.complete(Uint8List(1));
    await Future.wait([active.value, prefetch.value, interactive.value]);
    expect(started, ['tap', 'prefetch']);
  });

  test('joined consumers share bytes and one cancellation keeps other alive',
      () async {
    final scheduler = MediaLoadScheduler();
    final gate = Completer<Uint8List>();
    var calls = 0;
    final first = scheduler.request('same', () {
      calls++;
      return gate.future;
    });
    final second =
        scheduler.request('same', () => throw StateError('duplicate'));
    final canceled =
        expectLater(first.value, throwsA(isA<MediaLoadCanceled>()));
    first.cancel();
    gate.complete(Uint8List.fromList([1]));
    await canceled;
    expect(await second.value, [1]);
    expect(calls, 1);
  });

  test('last queued consumer cancels without starting its source', () async {
    final scheduler = MediaLoadScheduler(maxConcurrent: 1);
    final gate = Completer<Uint8List>();
    final active = scheduler.request('active', () => gate.future);
    await Future<void>.delayed(Duration.zero);
    var calls = 0;
    final queued = scheduler.request('queued', () async {
      calls++;
      return Uint8List(1);
    });
    expect(scheduler.queuedCount, 1);
    final assertion =
        expectLater(queued.value, throwsA(isA<MediaLoadCanceled>()));
    queued.cancel();
    await assertion;
    expect(scheduler.queuedCount, 0);
    gate.complete(Uint8List(1));
    await active.value;
    expect(calls, 0);
  });

  test('videos use one slot while a visible image can proceed', () async {
    final scheduler = MediaLoadScheduler(maxConcurrent: 3, maxVideos: 1);
    final video = Completer<Uint8List>();
    var secondStarted = false;
    final first = scheduler.request('v1', () => video.future, isVideo: true);
    final second = scheduler.request('v2', () async {
      secondStarted = true;
      return Uint8List(1);
    }, isVideo: true);
    final image = scheduler.request('image', () async => Uint8List(1));
    await image.value;
    expect(secondStarted, isFalse);
    video.complete(Uint8List(1));
    await Future.wait([first.value, second.value]);
  });

  test('failed tasks release slots and the key can retry', () async {
    final scheduler = MediaLoadScheduler(maxConcurrent: 1);
    await expectLater(
        scheduler.request('x', () => throw StateError('fail')).value,
        throwsStateError);
    expect(await scheduler.request('x', () async => Uint8List(2)).value,
        hasLength(2));
  });
}
