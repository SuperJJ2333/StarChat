import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/media_consumer_scope.dart';
import 'package:liuhetong_mobile/features/matrix/media_load_scheduler.dart';
import 'package:liuhetong_mobile/features/matrix/media_transfer_budget.dart';
import 'package:liuhetong_mobile/features/matrix/verified_media_content.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final cancelFirst in [false, true]) {
    test(
      'playback waits independent preparation: cancelFirst=$cancelFirst',
      () async {
        clearMediaMemoryCaches();
        final fixtures = await Directory(
          p.normalize(
            p.absolute(
              '../../docs/verification/artifacts/2026-10-11/im-media-cache-independent-review/fixtures',
            ),
          ),
        ).create(recursive: true);
        final root = await fixtures.createTemp('playback-prepare-');
        final previous = PathProviderPlatform.instance;
        final paths = _HeldPaths(root.path);
        PathProviderPlatform.instance = paths;
        final first = MediaConsumerScope();
        final second = MediaConsumerScope();
        final memory = MediaMemoryCache();
        const firstKey = MediaCacheKey(
          accountId: 'synthetic-playback',
          roomId: 'room',
          eventId: 'same-event',
          sourceIdentity: 'descriptor-a',
        );
        const secondKey = MediaCacheKey(
          accountId: 'synthetic-playback',
          roomId: 'room',
          eventId: 'same-event',
          sourceIdentity: 'descriptor-b',
        );
        final bytes = Uint8List.fromList([55, 56, 57]);
        mediaDigestObserver = (_, __) => paths.hold = true;
        Object? firstFailure;
        Object? secondFailure;
        File? secondResult;
        var secondCalls = 0;
        var secondFinished = false;
        Future<void>? secondObserved;
        final firstObserved = first
            .run(
              () => loadMediaWithCache(
                firstKey,
                () async => Uint8List.fromList(bytes),
                maximumBytes: 1024,
              ),
            )
            .then<void>((_) {}, onError: (Object e) => firstFailure = e);
        try {
          await paths.blocked.future.timeout(const Duration(seconds: 5));
          if (cancelFirst) {
            first.cancel();
            await firstObserved;
            expect(firstFailure, isA<MediaLoadCanceled>());
          }
          secondObserved = IOOverrides.runWithIOOverrides(
            () => second
                .run(
                  () => resolveCachedVideoFile(
                    key: secondKey,
                    memoryCache: memory,
                    loaderCachesContent: true,
                    decrypt: () =>
                        loadMediaWithCache(secondKey, () async {
                          secondCalls++;
                          return Uint8List.fromList(bytes);
                        }, maximumBytes: 1024).then((value) {
                          paths.secondSourceDone = true;
                          return value;
                        }),
                  ),
                )
                .then<void>((f) {
                  secondResult = f;
                }, onError: (Object e) => secondFailure = e)
                .whenComplete(() => secondFinished = true),
            _ObservePlaybackReads(paths),
          );
          await _waitFor(
            () =>
                secondCalls == 1 &&
                sharedMediaTransferBudget.activeBytes == 4096 &&
                mediaLoadScheduler.debugActiveCount == 1,
          );
          // B's actual source/store/index work has settled; only A retains the
          // reservation and root barrier. The public playback continuation has
          // entered preparePlaybackFile's wait set in the drained microtasks.
          await paths.secondAtPrepare.future.timeout(
            const Duration(seconds: 5),
          );
          expect(secondFinished, isFalse);
          expect(second.isActive, isTrue);
          final published = await MediaCache.cached(
            'room',
            'same-event',
            accountId: firstKey.accountId,
          );
          expect(await published!.readAsBytes(), bytes);
          paths.unblock();
          await Future.wait([firstObserved, secondObserved!]);
          await _waitFor(
            () =>
                mediaLoadScheduler.debugActiveCount == 0 &&
                sharedMediaTransferBudget.activeBytes == 0,
          );
          print(
            'synthetic_prepare_first_cancel=$cancelFirst second_active=${second.isActive} second_error=${secondFailure?.runtimeType}',
          );
          expect(
            secondFailure,
            isNull,
            reason:
                'A canceled independent preparation must not fail playback of B already published valid reference',
          );
          expect(await secondResult!.readAsBytes(), bytes);
        } finally {
          paths.unblock();
          first.cancel();
          second.cancel();
          await firstObserved;
          if (secondObserved != null) await secondObserved;
          await _waitFor(
            () =>
                mediaLoadScheduler.debugActiveCount == 0 &&
                sharedMediaTransferBudget.activeBytes == 0,
          );
          mediaDigestObserver = null;
          memory.dispose();
          clearMediaMemoryCaches();
          await MediaCache.closeQuotaIndexes();
          PathProviderPlatform.instance = previous;
          await root.delete(recursive: true);
        }
      },
    );
  }
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue, reason: 'Actual work did not reach its boundary');
}

final class _HeldPaths extends PathProviderPlatform {
  _HeldPaths(this.path);
  final String path;
  bool hold = false;
  bool held = false;
  bool secondSourceDone = false;
  final secondAtPrepare = Completer<void>();
  final blocked = Completer<void>();
  final release = Completer<void>();
  void unblock() {
    if (!release.isCompleted) release.complete();
  }

  @override
  Future<String?> getApplicationDocumentsPath() async {
    if (hold && !held) {
      held = true;
      blocked.complete();
      await release.future;
    }
    return path;
  }
}

final class _ObservePlaybackReads extends IOOverrides {
  _ObservePlaybackReads(this.paths) : previous = IOOverrides.current;
  final _HeldPaths paths;
  final IOOverrides? previous;
  @override
  File createFile(String path) {
    final real = previous?.createFile(path) ?? super.createFile(path);
    if (paths.secondSourceDone &&
        path.contains('/objects/') &&
        !path.endsWith('.len')) {
      return _ObservedReadFile(real, paths);
    }
    return real;
  }
}

final class _ObservedReadFile implements File {
  _ObservedReadFile(this.real, this.paths);
  final File real;
  final _HeldPaths paths;
  @override
  String get path => real.path;
  @override
  Uri get uri => real.uri;
  @override
  Directory get parent => real.parent;
  @override
  Future<bool> exists() => real.exists();
  @override
  Future<int> length() => real.length();
  @override
  Future<FileStat> stat() => real.stat();
  @override
  Future<Uint8List> readAsBytes() => real.readAsBytes();
  @override Future<RandomAccessFile> open({FileMode mode = FileMode.read}) => real.open(mode: mode);
  @override
  Stream<List<int>> openRead([int? start, int? end]) async* {
    yield* real.openRead(start, end);
    // The real indexed-cache verification ends before the microtasks unwind
    // _valid/cached and enter the synchronous playback preparation wait set.
    Timer.run(() {
      if (!paths.secondAtPrepare.isCompleted) paths.secondAtPrepare.complete();
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
