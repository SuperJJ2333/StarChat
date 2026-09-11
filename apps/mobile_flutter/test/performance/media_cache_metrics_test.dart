import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/media_consumer_scope.dart';
import 'package:liuhetong_mobile/features/matrix/media_load_scheduler.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const _metricsEnabled = bool.fromEnvironment('CHATFLOW_PERFORMANCE_METRICS');

int _counter(PerformanceCounter counter) {
  final counters = PerformanceMetrics.instance.snapshot()['counters'] as Map;
  return counters[counter.name] as int? ?? 0;
}

void _expectCounters({required int warmHits, required int flightJoins}) {
  final counters = PerformanceMetrics.instance.snapshot()['counters'] as Map;
  if (_metricsEnabled) {
    expect(_counter(PerformanceCounter.mediaMemoryHit), warmHits);
    expect(_counter(PerformanceCounter.mediaFlightJoin), flightJoins);
  } else {
    expect(counters, isEmpty,
        reason:
            'disabled metrics must not retain counters from real cache use');
  }
}

void _expectCounter(PerformanceCounter counter, Matcher matcher) {
  final counters = PerformanceMetrics.instance.snapshot()['counters'] as Map;
  if (_metricsEnabled) {
    expect(_counter(counter), matcher);
  } else {
    expect(counters, isEmpty,
        reason:
            'disabled metrics must not retain counters from real cache use');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PathProviderPlatform previousPaths;
  late Directory directory;

  setUp(() async {
    previousPaths = PathProviderPlatform.instance;
    PerformanceMetrics.instance.reset();
    clearMediaMemoryCaches();
    final root = await Directory(
            '../../docs/verification/artifacts/2026-09-11/performance/media-cache-metrics')
        .create(recursive: true);
    directory = await root.createTemp('metrics-');
    PathProviderPlatform.instance = _MetricsPaths(directory.path);
  });

  tearDown(() async {
    // Every test awaits its media work before this boundary; clearing prevents
    // a later test from retaining a memory-flight or scheduler owner.
    clearMediaMemoryCaches();
    PerformanceMetrics.instance.reset();
    PathProviderPlatform.instance = previousPaths;
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('a real memory-cache warm get records only its closed counter',
      () async {
    final cache = MediaMemoryCache();
    var loads = 0;
    try {
      final first = await cache.putIfAbsent('warm', () async {
        loads++;
        return Uint8List.fromList([1, 2, 3]);
      });
      final second = await cache.putIfAbsent('warm', () async {
        loads++;
        return Uint8List.fromList([4, 5, 6]);
      });

      expect(loads, 1);
      expect(identical(first, second), isTrue);
      _expectCounters(warmHits: 1, flightJoins: 0);
    } finally {
      cache.dispose();
    }
  });

  test('a second owner joining a held memory flight records only its counter',
      () async {
    final cache = MediaMemoryCache();
    final source = Completer<Uint8List>();
    var loads = 0;
    try {
      Future<Uint8List> load() {
        loads++;
        return source.future;
      }

      final first = cache.putIfAbsent('shared', load);
      final second = cache.putIfAbsent('shared', load);
      expect(loads, 1);

      source.complete(Uint8List.fromList([7, 8, 9]));
      final values = await Future.wait([first, second]);
      expect(identical(values.first, values.last), isTrue);
      _expectCounters(warmHits: 0, flightJoins: 1);
    } finally {
      if (!source.isCompleted) source.complete(Uint8List(0));
      cache.dispose();
    }
  });

  test('a second owner joining a held content flight records its counter',
      () async {
    final source = Completer<Uint8List>();
    final started = Completer<void>();
    final bytes = Uint8List.fromList([10, 11, 12]);
    final key = MediaCacheKey(
      accountId: 'metrics',
      roomId: 'content-flight',
      eventId: 'event',
      contentSha256: sha256.convert(bytes).toString(),
    );
    var decryptions = 0;
    Future<Uint8List> decrypt() {
      decryptions++;
      if (!started.isCompleted) started.complete();
      return source.future;
    }

    try {
      final first = loadMediaWithCache(key, decrypt);
      await started.future;
      final second = loadMediaWithCache(key, decrypt);
      source.complete(bytes);

      final values = await Future.wait([first, second]);
      expect(decryptions, 1);
      expect(identical(values.first, values.last), isTrue);
      _expectCounter(PerformanceCounter.mediaFlightJoin, equals(1));
    } finally {
      if (!source.isCompleted) source.complete(Uint8List(0));
    }
  });

  test('a cold media load then warm reuse records one real decrypt download',
      () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final key = MediaCacheKey(
      accountId: 'metrics',
      roomId: 'cold-warm',
      eventId: 'event',
      contentSha256: sha256.convert(bytes).toString(),
    );
    var decryptions = 0;
    Future<Uint8List> decrypt() async {
      decryptions++;
      return bytes;
    }

    final cold = await loadMediaWithCache(key, decrypt);
    final warm = await loadMediaWithCache(key, decrypt);

    expect(decryptions, 1);
    expect(identical(cold, warm), isTrue);
    _expectCounter(PerformanceCounter.mediaDownload, equals(1));
  });

  test('clearing memory retains a validated disk object without re-decrypting',
      () async {
    final bytes = Uint8List.fromList([4, 5, 6]);
    final key = MediaCacheKey(
      accountId: 'metrics',
      roomId: 'disk-reopen',
      eventId: 'event',
      contentSha256: sha256.convert(bytes).toString(),
    );
    var decryptions = 0;
    Future<Uint8List> decrypt() async {
      decryptions++;
      return bytes;
    }

    await loadMediaWithCache(key, decrypt);
    clearMediaMemoryCaches();
    final reopened = await loadMediaWithCache(key, decrypt);

    expect(decryptions, 1);
    expect(reopened, bytes);
    if (_metricsEnabled) {
      expect(_counter(PerformanceCounter.mediaDownload), 1);
      expect(
          _counter(PerformanceCounter.mediaDiskHit), greaterThanOrEqualTo(1));
    } else {
      expect(PerformanceMetrics.instance.snapshot()['counters'], isEmpty);
    }
  });

  test('last queued media owner cancellation does not record a download',
      () async {
    final blockers = List.generate(3, (_) => Completer<Uint8List>());
    final leases = [
      for (var index = 0; index < blockers.length; index++)
        mediaLoadScheduler.request(
            'metrics-blocker-$index', () => blockers[index].future),
    ];
    final scope = MediaConsumerScope();
    var decryptions = 0;
    Future<Uint8List>? queued;
    try {
      await _waitFor(() => mediaLoadScheduler.debugActiveCount == 3);
      queued = scope.run(() => loadMediaWithCache(
              const MediaCacheKey(
                  accountId: 'metrics',
                  roomId: 'cancel',
                  eventId: 'event'), () async {
            decryptions++;
            return Uint8List.fromList([1]);
          }));
      await _waitFor(() => mediaLoadScheduler.debugQueuedCount == 1);

      scope.cancel();
      await expectLater(queued, throwsA(isA<MediaLoadCanceled>()));
      expect(decryptions, 0);
      _expectCounter(PerformanceCounter.mediaDownload, equals(0));
    } finally {
      scope.cancel();
      for (final blocker in blockers) {
        if (!blocker.isCompleted) blocker.complete(Uint8List(0));
      }
      await Future.wait<void>([
        for (final lease in leases)
          lease.value.then<void>((_) {}, onError: (Object _) {}),
        if (queued != null) queued.then<void>((_) {}, onError: (Object _) {}),
      ]);
      await _waitFor(() =>
          mediaLoadScheduler.debugActiveCount == 0 &&
          mediaLoadScheduler.debugQueuedCount == 0);
    }
  });
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue, reason: 'Timed out waiting for scheduler state');
}

final class _MetricsPaths extends PathProviderPlatform {
  _MetricsPaths(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}
