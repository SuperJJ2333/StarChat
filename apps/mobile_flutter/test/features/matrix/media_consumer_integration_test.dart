import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_consumer_scope.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:liuhetong_mobile/features/matrix/media_load_scheduler.dart';
import 'package:liuhetong_mobile/features/matrix/room_image_preview_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PathProviderPlatform previousPaths;
  setUp(() async {
    previousPaths = PathProviderPlatform.instance;
    clearMediaMemoryCaches();
    final root = await Directory(
            '../../docs/verification/artifacts/2026-09-11/performance/consumer-integration')
        .create(recursive: true);
    final directory = await root.createTemp('media-consumer-');
    PathProviderPlatform.instance = _IntegrationPaths(directory.path);
    addTearDown(() async {
      clearMediaMemoryCaches();
      PathProviderPlatform.instance = previousPaths;
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });
  test('scoped preview callers share one source while one cancels', () async {
    final held = Completer<Uint8List>();
    final bytes = Uint8List.fromList([1, 2, 3]);
    final hash = sha256.convert(bytes).toString();
    var calls = 0;
    final cache = RoomImagePreviewCache(
        accountId: 'integration-a',
        roomId: 'room',
        read: (_) async => null,
        write: (_, __) async {});
    final a = MediaConsumerScope();
    final b = MediaConsumerScope();
    Future<Uint8List> source() => loadMediaWithCache(
            MediaCacheKey(
                accountId: 'integration-a',
                roomId: 'room',
                eventId: 'event',
                contentSha256: hash), () {
          calls++;
          return held.future;
        });
    final first = a.run(() => cache.load('event', source));
    final second = b.run(() => cache.load('event', source));
    final canceled = expectLater(first, throwsA(isA<MediaLoadCanceled>()));
    try {
      a.cancel();
      held.complete(bytes);
      await canceled;
      expect(await second, bytes);
      expect(calls, 1);
    } finally {
      if (!held.isCompleted) held.complete(bytes);
      cache.dispose();
    }
  });

  test('last queued scoped preview cancellation never starts decrypt',
      () async {
    final cache = RoomImagePreviewCache(
        accountId: 'integration-b',
        roomId: 'room',
        read: (_) async => null,
        write: (_, __) async {});
    final blockers = List.generate(3, (_) => Completer<Uint8List>());
    final leases = [
      for (var i = 0; i < 3; i++)
        mediaLoadScheduler.request(
            'integration-block-$i', () => blockers[i].future),
    ];
    await Future<void>.delayed(Duration.zero);
    expect(mediaLoadScheduler.debugActiveCount, 3);
    final scope = MediaConsumerScope();
    var calls = 0;
    final key = MediaCacheKey(
        accountId: 'integration-b', roomId: 'room', eventId: 'event');
    final queued = scope.run(() => cache.load(
        'event',
        () => loadMediaWithCache(key, () async {
              calls++;
              return Uint8List(1);
            })));
    final canceled = expectLater(queued, throwsA(isA<MediaLoadCanceled>()));
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (mediaLoadScheduler.debugQueuedCount == 0 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(mediaLoadScheduler.debugQueuedCount, 1);
      scope.cancel();
      await canceled;
      for (final blocker in blockers) {
        if (!blocker.isCompleted) blocker.complete(Uint8List(1));
      }
      await Future.wait([for (final lease in leases) lease.value]);
      while ((mediaLoadScheduler.debugActiveCount != 0 ||
              mediaLoadScheduler.debugQueuedCount != 0) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(calls, 0);
    } finally {
      scope.cancel();
      for (final blocker in blockers) {
        if (!blocker.isCompleted) blocker.complete(Uint8List(1));
      }
      await Future.wait([for (final lease in leases) lease.value]);
      cache.dispose();
    }
  });

  test('a new preview joins an active decrypt after the first scope cancels',
      () async {
    final held = Completer<Uint8List>();
    final started = Completer<void>();
    final bytes = Uint8List.fromList([4, 5, 6]);
    final hash = sha256.convert(bytes).toString();
    final firstCache = RoomImagePreviewCache(
        accountId: 'integration-c',
        roomId: 'room-a',
        read: (_) async => null,
        write: (_, __) async {});
    final secondCache = RoomImagePreviewCache(
        accountId: 'integration-c',
        roomId: 'room-b',
        read: (_) async => null,
        write: (_, __) async {});
    final firstScope = MediaConsumerScope();
    final secondScope = MediaConsumerScope();
    var decryptCalls = 0;
    Future<Uint8List> source() => loadMediaWithCache(
            MediaCacheKey(
                accountId: 'integration-c',
                roomId: 'shared-room',
                eventId: 'shared-event',
                contentSha256: hash), () {
          decryptCalls++;
          started.complete();
          return held.future;
        });
    final first = firstScope.run(() => firstCache.load('event-a', source));
    final canceled = expectLater(first, throwsA(isA<MediaLoadCanceled>()));
    try {
      await started.future;
      firstScope.cancel();
      await canceled;
      expect(mediaLoadScheduler.debugActiveCount, 1);
      expect(mediaLoadScheduler.debugConsumerCount, 0);

      final second = secondScope.run(() => secondCache.load('event-b', source));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while ((mediaLoadScheduler.debugActiveCount != 1 ||
              mediaLoadScheduler.debugConsumerCount != 1) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(mediaLoadScheduler.debugActiveCount, 1);
      expect(mediaLoadScheduler.debugConsumerCount, 1);
      held.complete(bytes);
      expect(await second, bytes);
      expect(decryptCalls, 1);
    } finally {
      firstScope.cancel();
      secondScope.cancel();
      if (!held.isCompleted) held.complete(bytes);
      firstCache.dispose();
      secondCache.dispose();
    }
  });

  test('explicit prefetch stays behind a later visible media request',
      () async {
    final blockers = List.generate(3, (_) => Completer<Uint8List>());
    final leases = [
      for (var i = 0; i < blockers.length; i++)
        mediaLoadScheduler.request(
            'priority-block-$i', () => blockers[i].future),
    ];
    final prefetch = Completer<Uint8List>();
    final visible = Completer<Uint8List>();
    final started = <String>[];
    final prefetchKey = MediaCacheKey(
        accountId: 'integration-priority', roomId: 'room', eventId: 'prefetch');
    final visibleKey = MediaCacheKey(
        accountId: 'integration-priority', roomId: 'room', eventId: 'visible');
    Future<Uint8List>? prefetchLoad;
    Future<Uint8List>? visibleLoad;
    try {
      await _waitFor(() => mediaLoadScheduler.debugActiveCount == 3);
      prefetchLoad = loadMediaWithCache(prefetchKey, () {
        started.add('prefetch');
        return prefetch.future;
      }, priority: MediaLoadPriority.prefetch);
      await _waitFor(() => mediaLoadScheduler.debugQueuedCount == 1);
      visibleLoad = loadMediaWithCache(visibleKey, () {
        started.add('visible');
        return visible.future;
      }, priority: MediaLoadPriority.visible);
      await _waitFor(() => mediaLoadScheduler.debugQueuedCount == 2);

      blockers.first.complete(Uint8List(1));
      await _waitFor(() => started.isNotEmpty);
      expect(started, ['visible']);

      visible.complete(Uint8List(2));
      await _waitFor(() => started.length == 2);
      prefetch.complete(Uint8List(3));
      for (final blocker in blockers.skip(1)) {
        if (!blocker.isCompleted) blocker.complete(Uint8List(1));
      }
      await Future.wait(
          [prefetchLoad, visibleLoad, ...leases.map((lease) => lease.value)]);
    } finally {
      for (final blocker in blockers) {
        if (!blocker.isCompleted) blocker.complete(Uint8List(1));
      }
      if (!prefetch.isCompleted) prefetch.complete(Uint8List(3));
      if (!visible.isCompleted) visible.complete(Uint8List(2));
      await Future.wait<void>([
        for (final lease in leases) lease.value.catchError((_) => Uint8List(0)),
        if (prefetchLoad != null) prefetchLoad.catchError((_) => Uint8List(0)),
        if (visibleLoad != null) visibleLoad.catchError((_) => Uint8List(0)),
      ]);
    }
  });

  test('a queued scoped prefetch is promoted ahead of visible work', () async {
    final blockers = List.generate(3, (_) => Completer<Uint8List>());
    final leases = [
      for (var i = 0; i < blockers.length; i++)
        mediaLoadScheduler.request(
            'promotion-block-$i', () => blockers[i].future),
    ];
    final promoted = Completer<Uint8List>();
    final visible = Completer<Uint8List>();
    final started = <String>[];
    final scope = MediaConsumerScope(priority: MediaLoadPriority.prefetch);
    Future<Uint8List>? promotedLoad;
    Future<Uint8List>? visibleLoad;
    try {
      await _waitFor(() => mediaLoadScheduler.debugActiveCount == 3);
      promotedLoad = scope.run(() => loadMediaWithCache(
              const MediaCacheKey(
                  accountId: 'integration-promotion',
                  roomId: 'room',
                  eventId: 'prefetch'), () {
            started.add('promoted');
            return promoted.future;
          }));
      await _waitFor(() => mediaLoadScheduler.debugQueuedCount == 1);
      visibleLoad = loadMediaWithCache(
          const MediaCacheKey(
              accountId: 'integration-promotion',
              roomId: 'room',
              eventId: 'visible'), () {
        started.add('visible');
        return visible.future;
      }, priority: MediaLoadPriority.visible);
      await _waitFor(() => mediaLoadScheduler.debugQueuedCount == 2);

      scope.promote(MediaLoadPriority.interactive);
      blockers.first.complete(Uint8List(1));
      await _waitFor(() => started.isNotEmpty);
      expect(started, ['promoted']);

      promoted.complete(Uint8List(2));
      await _waitFor(() => started.length == 2);
      visible.complete(Uint8List(3));
      for (final blocker in blockers.skip(1)) {
        if (!blocker.isCompleted) blocker.complete(Uint8List(1));
      }
      await Future.wait(
          [promotedLoad, visibleLoad, ...leases.map((lease) => lease.value)]);
    } finally {
      scope.cancel();
      for (final blocker in blockers) {
        if (!blocker.isCompleted) blocker.complete(Uint8List(1));
      }
      if (!promoted.isCompleted) promoted.complete(Uint8List(2));
      if (!visible.isCompleted) visible.complete(Uint8List(3));
      await Future.wait<void>([
        for (final lease in leases) lease.value.catchError((_) => Uint8List(0)),
        if (promotedLoad != null) promotedLoad.catchError((_) => Uint8List(0)),
        if (visibleLoad != null) visibleLoad.catchError((_) => Uint8List(0)),
      ]);
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

final class _IntegrationPaths extends PathProviderPlatform {
  _IntegrationPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}
