import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/media_consumer_scope.dart';
import 'package:liuhetong_mobile/features/matrix/media_load_scheduler.dart';
import 'package:liuhetong_mobile/features/matrix/media_transfer_budget.dart';
import 'package:liuhetong_mobile/features/matrix/verified_media_content.dart';

class HeldStorePaths extends PathProviderPlatform {
  HeldStorePaths(this.path);
  final String path;
  bool verified = false;
  bool heldOnce = false;
  final blocked = Completer<void>();
  final release = Completer<void>();
  @override
  Future<String?> getApplicationDocumentsPath() async {
    // The first path lookup after the real digest worker returned is the
    // store preparation's _root. No object write has started at this point.
    if (verified && !heldOnce) {
      heldOnce = true;
      blocked.complete();
      await release.future;
    }
    return path;
  }
}

Future<void> settled() async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while ((mediaLoadScheduler.debugActiveCount != 0 || sharedMediaTransferBudget.activeBytes != 0) && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(mediaLoadScheduler.debugActiveCount, 0);
  expect(sharedMediaTransferBudget.activeBytes, 0);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final cancelAfterPreparation in [false, true]) {
    test('store preparation observer cancellation ($cancelAfterPreparation)', () async {
      clearMediaMemoryCaches();
      final directory = await Directory('../../docs/verification/artifacts/2026-10-11/im-media-cache-independent-review/fixtures').absolute.create(recursive: true);
      final root = await directory.createTemp('late-cancel-');
      final previous = PathProviderPlatform.instance;
      final paths = HeldStorePaths(root.path);
      PathProviderPlatform.instance = paths;
      final observer = MediaConsumerScope();
      final bytes = Uint8List.fromList([101, 102, 103]);
      final hash = sha256.convert(bytes).toString();
      const account = 'independent-synthetic';
      final key = MediaCacheKey(accountId: account, roomId: 'r', eventId: 'e', contentSha256: hash);
      Object? failure;
      mediaDigestObserver = (_, __) => paths.verified = true;
      final load = observer.run(() => loadMediaWithCache(key, () async => bytes, maximumBytes: 1024));
      final observed = load.then<void>((_) {}, onError: (Object error) { failure = error; });
      try {
        await paths.blocked.future.timeout(const Duration(seconds: 5));
        expect(paths.verified, isTrue);
        if (!const bool.fromEnvironment('REVIEW_BASE')) {
          expect(mediaLoadScheduler.debugActiveCount, 1);
        }
        final object = File('${root.path}/chat-media/v2/${sha256.convert(utf8.encode(account))}/objects/$hash');
        expect(await object.exists(), isFalse);
        if (cancelAfterPreparation) {
          observer.cancel();
          await observed;
          expect(failure, isA<MediaLoadCanceled>());
          expect(mediaLoadScheduler.debugConsumerCount, 0);
          expect(sharedMediaTransferBudget.activeBytes, greaterThan(0));
        }
        final completedStore = MediaCache.preparePlaybackFile('r', 'e', accountId: account)
            .then<void>((_) {}, onError: (Object _) {});
        paths.release.complete();
        await observed;
        await completedStore;
        await settled();
        expect(sharedMediaTransferBudget.activeBytes, 0);
        final cached = await MediaCache.cached('r', 'e', accountId: account, contentSha256: hash);
        print('synthetic_cancel=$cancelAfterPreparation cache_published=${cached != null}');
        if (cancelAfterPreparation) {
          expect(cached, isNull, reason: 'No observer remained before store root preparation finished; no object should publish');
        } else {
          expect(failure, isNull);
          expect(await cached!.readAsBytes(), bytes);
        }
      } finally {
        if (!paths.release.isCompleted) paths.release.complete();
        observer.cancel();
        await observed;
        await settled();
        mediaDigestObserver = null;
        clearMediaMemoryCaches();
        await MediaCache.closeQuotaIndexes();
        PathProviderPlatform.instance = previous;
        if (await root.exists()) await root.delete(recursive: true);
      }
    });
  }
}
