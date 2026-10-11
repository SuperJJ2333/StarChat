import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
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
  for (final (cancelFirst, cancelSecond, sameReference) in [
    (false, false, false),
    (true, false, false),
    (true, true, false),
    (true, false, true)
  ]) {
    test(
      'public playback path with shared verified object: cancelFirst=$cancelFirst cancelSecond=$cancelSecond sameReference=$sameReference',
      () async {
        clearMediaMemoryCaches();
        final fixtures = await Directory(
          p.normalize(
            p.absolute(
              '../../docs/verification/artifacts/2026-10-11/im-media-cache-independent-review/fixtures',
            ),
          ),
        ).create(recursive: true);
        final root = await fixtures.createTemp('object-flight-');
        final previous = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _Paths(root.path);
        const account = 'synthetic-independent-object-join';
        final bytes = Uint8List.fromList([125, 126, 127]);
        final digest = sha256.convert(bytes).toString();
        final accountRoot =
            '${root.path}/chat-media/v2/${sha256.convert(utf8.encode(account))}';
        final files = _HeldFiles('$accountRoot/objects/$digest', accountRoot);
        final first = MediaConsumerScope();
        final second = MediaConsumerScope();
        var firstCalls = 0;
        var secondCalls = 0;
        Object? firstFailure;
        Object? secondFailure;
        Uint8List? secondResult;
        mediaDigestObserver = (_, __) {
          if (Zone.current[#secondLegacySource] == true) {
            files.secondVerified = true;
            if (sameReference) {
              // The old same-reference shortcut joins before requesting root.
              // Otherwise wait for the observed real directory creation below.
              Timer.run(() {
                if (!files.observedSecondStore &&
                    !files.secondAtObjectFlight.isCompleted) {
                  files.secondAtObjectFlight.complete();
                }
              });
            }
          }
        };
        Future<void>? secondObserved;
        final firstObserved = IOOverrides.runWithIOOverrides(
          () => first
              .run(
                () => loadMediaWithCache(
                  const MediaCacheKey(
                    accountId: account,
                    roomId: 'room',
                    eventId: 'event-a',
                    sourceIdentity: 'descriptor-a',
                  ),
                  () async {
                    firstCalls++;
                    return Uint8List.fromList(bytes);
                  },
                  maximumBytes: 1024,
                ),
              )
              .then<void>((_) {}, onError: (Object e) => firstFailure = e),
          files,
        );
        try {
          await files.blocked.future.timeout(const Duration(seconds: 5));
          secondObserved = IOOverrides.runWithIOOverrides(
            () => runZoned(
              () => second
                  .run(
                () => _loadForPlayback(
                  MediaCacheKey(
                    accountId: account,
                    roomId: 'room',
                    eventId: sameReference ? 'event-a' : 'event-b',
                    sourceIdentity: 'descriptor-b',
                  ),
                  () async {
                    secondCalls++;
                    return Uint8List.fromList(bytes);
                  },
                  maximumBytes: 1024,
                ),
              )
                  .then<void>((value) {
                secondResult = value;
              }, onError: (Object e) => secondFailure = e),
              zoneValues: {#secondLegacySource: true},
            ),
            files,
          );
          // This event runs after the second verified store's account directory
          // creation has returned, and all resulting microtasks have drained.
          // _root.then -> _store reaches await _objectFlights synchronously.
          await files.secondAtObjectFlight.future.timeout(
            const Duration(seconds: 5),
          );
          expect(firstCalls, 1);
          expect(secondCalls, 1);
          expect(mediaLoadScheduler.debugActiveCount, 2);
          expect(mediaLoadScheduler.debugConsumerCount, 2);
          if (cancelFirst) {
            first.cancel();
            await firstObserved;
            expect(firstFailure, isA<MediaLoadCanceled>());
            expect(mediaLoadScheduler.debugConsumerCount, 1);
            expect(second.isActive, isTrue);
          }
          expect(await File(files.target).exists(), isFalse);
          if (cancelSecond) {
            second.cancel();
            await secondObserved;
            expect(secondFailure, isA<MediaLoadCanceled>());
            expect(mediaLoadScheduler.debugConsumerCount, 0);
          }
          expect(sharedMediaTransferBudget.activeBytes, 8192,
              reason: 'Both verified sources retain their real write lifetime');
          files.unblock();
          await Future.wait([firstObserved, secondObserved!]);
          await _settled();
          expect(files.objectWrites, 1,
              reason:
                  'Shared demand must not retry or duplicate the object write');
          if (cancelSecond) {
            expect(await File(files.target).exists(), isFalse);
          } else {
            expect(secondFailure, isNull,
                reason:
                    'An independent live source must not inherit another source cancellation');
            expect(secondResult, bytes);
            final secondCached = await MediaCache.cached(
                'room', sameReference ? 'event-a' : 'event-b',
                accountId: account);
            expect(await secondCached!.readAsBytes(), bytes);
          }
          final firstCached =
              await MediaCache.cached('room', 'event-a', accountId: account);
          expect(firstCached == null, cancelFirst && !sameReference,
              reason: 'Each reference keeps its own source demand');
          if (!cancelFirst) expect(firstFailure, isNull);
        } finally {
          files.unblock();
          first.cancel();
          second.cancel();
          await firstObserved;
          if (secondObserved != null) await secondObserved;
          await _settled();
          mediaDigestObserver = null;
          clearMediaMemoryCaches();
          await MediaCache.closeQuotaIndexes();
          PathProviderPlatform.instance = previous;
          await root.delete(recursive: true);
        }
      },
    );
  }
}

Future<void> _settled() async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while ((mediaLoadScheduler.debugActiveCount != 0 ||
          sharedMediaTransferBudget.activeBytes != 0) &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(mediaLoadScheduler.debugActiveCount, 0);
  expect(sharedMediaTransferBudget.activeBytes, 0);
}

final class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

final class _HeldFiles extends IOOverrides {
  _HeldFiles(this.target, this.accountRoot) : previous = IOOverrides.current;
  final String target;
  final String accountRoot;
  final IOOverrides? previous;
  bool secondVerified = false;
  bool observedSecondStore = false;
  int objectWrites = 0;
  final blocked = Completer<void>();
  final release = Completer<void>();
  final secondAtObjectFlight = Completer<void>();
  void unblock() {
    if (!release.isCompleted) release.complete();
  }

  @override
  File createFile(String path) {
    final real = previous?.createFile(path) ?? super.createFile(path);
    return path.startsWith('$target.') &&
            !path.startsWith('$target.len.') &&
            path.endsWith('.tmp')
        ? _HeldFile(real, this)
        : real;
  }

  @override
  Directory createDirectory(String path) {
    final real = previous?.createDirectory(path) ?? super.createDirectory(path);
    if (Zone.current[#secondLegacySource] == true &&
        secondVerified &&
        !observedSecondStore &&
        p.equals(p.normalize(path), p.normalize(accountRoot))) {
      observedSecondStore = true;
      return _ObservedDirectory(real, this);
    }
    return real;
  }
}

final class _ObservedDirectory implements Directory {
  _ObservedDirectory(this.real, this.owner);
  final Directory real;
  final _HeldFiles owner;
  @override
  Future<Directory> create({bool recursive = false}) async {
    final result = await real.create(recursive: recursive);
    Timer.run(() {
      if (!owner.secondAtObjectFlight.isCompleted) {
        owner.secondAtObjectFlight.complete();
      }
    });
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _HeldFile implements File {
  _HeldFile(this.real, this.owner);
  final File real;
  final _HeldFiles owner;
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    owner.objectWrites++;
    await real.writeAsBytes(bytes, mode: mode, flush: flush);
    if (!owner.blocked.isCompleted) {
      owner.blocked.complete();
      await owner.release.future;
    }
    return this;
  }

  @override
  Future<bool> exists() => real.exists();
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      real.delete(recursive: recursive);
  @override
  Future<File> rename(String path) => real.rename(path);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<Uint8List> _loadForPlayback(MediaCacheKey key,
    Future<Uint8List> Function() decrypt, {required int maximumBytes}) async {
  final memory = MediaMemoryCache();
  try {
    final file = await resolveCachedVideoFile(
      key: key,
      loaderCachesContent: true,
      memoryCache: memory,
      decrypt: () => loadMediaWithCache(key, decrypt, maximumBytes: maximumBytes),
    );
    return await file.readAsBytes();
  } finally {
    memory.dispose();
  }
}
