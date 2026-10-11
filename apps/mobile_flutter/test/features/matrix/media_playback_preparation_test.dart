import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/media_consumer_scope.dart';
import 'package:liuhetong_mobile/features/matrix/media_load_scheduler.dart';
import 'package:liuhetong_mobile/features/matrix/media_transfer_budget.dart';
import 'package:liuhetong_mobile/features/matrix/verified_media_content.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

enum _Boundary {
  valid,
  callerCancel,
  noCache,
  corrupt,
  accountClear,
  globalClear,
  laterIoFailure
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final boundary in _Boundary.values) {
    test('playback preparation cancellation boundary: ${boundary.name}',
        () async {
      clearMediaMemoryCaches();
      final fixtures = await Directory(p.normalize(p.absolute(
        '../../docs/verification/artifacts/2026-10-11/im-media-cache-regression/fixtures',
      ))).create(recursive: true);
      final root = await fixtures.createTemp('playback-preparation-');
      final previous = PathProviderPlatform.instance;
      final paths = _HeldPaths(root.path);
      PathProviderPlatform.instance = paths;
      final first = MediaConsumerScope();
      final other = MediaConsumerScope();
      final player = MediaConsumerScope();
      final bytes = Uint8List.fromList([81, 82, 83]);
      const account = 'synthetic-playback-preparation';
      mediaDigestObserver = (_, __) {
        final label = Zone.current[#preparationSource];
        if (label is String) paths.verifying.add(label);
      };
      Future<void> start(String label, MediaConsumerScope scope) => runZoned(
            () => scope
                .run(() => loadMediaWithCache(
                      MediaCacheKey(
                          accountId: account,
                          roomId: 'room',
                          eventId: 'event',
                          sourceIdentity: label),
                      () async => Uint8List.fromList(bytes),
                      maximumBytes: 1024,
                    ))
                .then<void>((_) {}, onError: (Object _) {}),
            zoneValues: {#preparationSource: label},
          );
      final firstObserved = start('a', first);
      Future<void>? otherObserved;
      Future<void>? clear;
      Future<void>? playbackObserved;
      File? result;
      Object? failure;
      var finished = false;
      try {
        await paths.blocked('a').future.timeout(const Duration(seconds: 5));
        if (boundary == _Boundary.laterIoFailure) {
          paths.fail.add('c');
          otherObserved = start('c', other);
          await paths.blocked('c').future.timeout(const Duration(seconds: 5));
        }
        final published = boundary == _Boundary.noCache
            ? null
            : await MediaCache.store(
                'room',
                'event',
                Uint8List.fromList(bytes),
                accountId: account,
              );
        first.cancel();
        await firstObserved;
        if (boundary == _Boundary.corrupt) {
          await published!.writeAsBytes([91, 92, 93], flush: true);
        }
        // Direct public prepare snapshots its wait set synchronously before its
        // first await. A's real root preparation is still held at this point.
        playbackObserved = player
            .run(() => MediaCache.preparePlaybackFile(
                  'room',
                  'event',
                  accountId: account,
                ))
            .then<void>((value) {
          result = value;
        }, onError: (Object error) {
          failure = error;
        }).whenComplete(() => finished = true);
        expect(finished, isFalse);
        expect(sharedMediaTransferBudget.activeBytes,
            boundary == _Boundary.laterIoFailure ? 8192 : 4096);
        switch (boundary) {
          case _Boundary.callerCancel:
            player.cancel();
          case _Boundary.accountClear:
            clear = MediaCache.clearAccount(account);
          case _Boundary.globalClear:
            clearMediaMemoryCaches();
          default:
            break;
        }
        paths.unblock('a');
        if (boundary == _Boundary.laterIoFailure) {
          await _waitFor(() => mediaLoadScheduler.debugActiveCount == 1);
          expect(finished, isFalse,
              reason: 'Must wait for later real I/O settlement');
          expect(sharedMediaTransferBudget.activeBytes, 4096);
          paths.unblock('c');
        }
        await playbackObserved.timeout(const Duration(seconds: 5));
        if (clear != null) await clear;
        await _waitFor(() =>
            mediaLoadScheduler.debugActiveCount == 0 &&
            sharedMediaTransferBudget.activeBytes == 0);
        if (boundary == _Boundary.valid) {
          expect(failure, isNull);
          expect(await result!.readAsBytes(), bytes);
        } else {
          expect(result, isNull);
          if (boundary == _Boundary.laterIoFailure) {
            expect(failure, isA<FileSystemException>());
            expect((failure as FileSystemException).message,
                'synthetic preparation I/O failure');
          } else if (boundary == _Boundary.accountClear ||
              boundary == _Boundary.globalClear) {
            expect(
                failure,
                isA<StateError>().having(
                    (e) => e is MediaLoadCanceled, 'is cancellation', isFalse));
          } else {
            expect(failure, isA<MediaLoadCanceled>());
          }
        }
      } finally {
        paths.unblock('a');
        paths.unblock('c');
        first.cancel();
        other.cancel();
        player.cancel();
        await firstObserved;
        if (otherObserved != null) await otherObserved;
        if (playbackObserved != null) await playbackObserved;
        if (clear != null) await clear;
        await _waitFor(() =>
            mediaLoadScheduler.debugActiveCount == 0 &&
            sharedMediaTransferBudget.activeBytes == 0);
        mediaDigestObserver = null;
        clearMediaMemoryCaches();
        await MediaCache.closeQuotaIndexes();
        PathProviderPlatform.instance = previous;
        await root.delete(recursive: true);
      }
    });
  }
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue, reason: 'Actual preparation did not settle');
}

final class _HeldPaths extends PathProviderPlatform {
  _HeldPaths(this.path);
  final String path;
  final verifying = <String>{};
  final held = <String>{};
  final fail = <String>{};
  final _blocked = <String, Completer<void>>{};
  final _release = <String, Completer<void>>{};
  Completer<void> blocked(String label) =>
      _blocked.putIfAbsent(label, Completer<void>.new);
  void unblock(String label) {
    final gate = _release.putIfAbsent(label, Completer<void>.new);
    if (!gate.isCompleted) gate.complete();
  }

  @override
  Future<String?> getApplicationDocumentsPath() async {
    final label = Zone.current[#preparationSource];
    if (label is String && verifying.contains(label) && held.add(label)) {
      blocked(label).complete();
      await _release.putIfAbsent(label, Completer<void>.new).future;
      if (fail.contains(label)) {
        throw const FileSystemException('synthetic preparation I/O failure');
      }
    }
    return path;
  }
}
