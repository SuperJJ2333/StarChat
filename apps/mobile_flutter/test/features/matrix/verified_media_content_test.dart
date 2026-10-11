import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../media/media_test_fixtures.dart';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/content_addressed_media.dart';
import 'package:liuhetong_mobile/features/matrix/media_consumer_scope.dart';
import 'package:liuhetong_mobile/features/matrix/media_load_scheduler.dart';
import 'package:liuhetong_mobile/features/matrix/media_memory_budget.dart';
import 'package:liuhetong_mobile/features/matrix/room_image_preview_cache.dart';
import 'package:liuhetong_mobile/features/matrix/verified_media_content.dart';
import 'package:liuhetong_mobile/features/matrix/media_transfer_budget.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  setUp(() async {
    clearMediaMemoryCaches();
    final root = await Directory.fromUri(Directory.current.uri.resolve(
      '../../docs/verification/artifacts/2026-10-11/im-media-hash/fixtures/',
    )).create(recursive: true);
    final dir = await root.createTemp('cache-');
    PathProviderPlatform.instance = _Paths(dir.path);
    addTearDown(() async {
      mediaDigestObserver = null;
      clearMediaMemoryCaches();
      await dir.delete(recursive: true);
    });
  });

  test('100 MiB cold load uses one worker digest through store and memory',
      () async {
    final input = Uint8List(100 * 1024 * 1024)..[0] = 71;
    final hash = sha256.convert(input).toString();
    final work = <(int, bool)>[];
    var ticks = 0;
    final timer =
        Timer.periodic(const Duration(milliseconds: 1), (_) => ticks++);
    addTearDown(timer.cancel);
    mediaDigestObserver = (length, worker) {
      expect(ticks, greaterThan(0), reason: 'UI loop progresses during digest');
      work.add((length, worker));
    };
    // Explicit synthetic capacity keeps the R7b 100MiB digest workload while
    // production's 192MiB default rejects this full-buffer operation.
    final bytes = await MediaTransferBudget(maxBytes: 400 * 1024 * 1024).run(
        MediaTransferPlan.download(input.length),
        () => loadMediaWithCache(
              MediaCacheKey(
                  accountId: 'alice',
                  roomId: 'room',
                  eventId: 'event',
                  contentSha256: hash),
              () async => input,
            ));
    expect(bytes.length, input.length);
    expect(work, [(input.length, true)]);
  });

  test('large immediate preview does no synchronous digest', () async {
    final preview = RoomImagePreviewCache(accountId: 'alice', roomId: 'room');
    addTearDown(preview.dispose);
    final bytes = Uint8List(2 * 1024 * 1024)..[0] = 7;
    final verified = Completer<void>();
    final work = <bool>[];
    mediaDigestObserver = (_, worker) {
      work.add(worker);
      if (!verified.isCompleted) verified.complete();
    };
    preview.seed('local', bytes);
    final immediate = preview.get('local')!;
    expect(immediate[0], 7);
    bytes[0] = 9;
    expect(immediate[0], 7);
    expect(work, isEmpty, reason: 'seed must yield before digest work');
    await verified.future;
    expect(work, [true]);
  });

  test('proof owns bytes and cannot be reused for a forged hash or new epoch',
      () async {
    final original = Uint8List.fromList([1, 2, 3]);
    var digests = 0;
    mediaDigestObserver = (_, worker) {
      expect(worker, isTrue);
      digests++;
    };
    final scope = MediaCache.verificationScope('alice');
    final proof = await VerifiedMediaContent.verify(original, scope: scope);
    original[0] = 9;
    expect(proof.bytes, [1, 2, 3]);
    expect(() => proof.bytes[0] = 9, throwsUnsupportedError);
    expect(
        () => proof.bytes.buffer.asUint8List()[0] = 9, throwsUnsupportedError);
    expect(await VerifiedMediaContent.verify(proof.bytes, scope: scope),
        same(proof));
    await expectLater(
        VerifiedMediaContent.verify(proof.bytes,
            scope: scope, expectedSha256: sha256.convert([9]).toString()),
        throwsFormatException);
    final bob = await VerifiedMediaContent.verify(proof.bytes,
        scope: MediaCache.verificationScope('bob'));
    expect(bob.bytes, isNot(same(proof.bytes)));
    clearMediaMemoryCaches();
    final next = await VerifiedMediaContent.verify(proof.bytes,
        scope: MediaCache.verificationScope('alice'));
    expect(next, isNot(same(proof)));
    expect(digests, 3);
    await expectLater(
        VerifiedMediaContent.verify(original,
            scope: scope, expectedSha256: proof.digest),
        throwsFormatException);
  });

  test('outgoing cache and encryption share one final-byte digest', () async {
    final bytes = Uint8List(2 * 1024 * 1024)..[0] = 13;
    final work = <bool>[];
    mediaDigestObserver = (_, worker) => work.add(worker);
    final prepared = await prepareContentAddressedMedia(
      file: MatrixFile(bytes: bytes, name: 'payload.bin'),
      accountId: 'alice',
      cacheContent: (input) =>
          cacheOutgoingMedia(accountId: 'alice', roomId: 'room', bytes: input),
    );
    expect(work, [true]);
    expect(prepared.extraContent!['chatflow_media']['content_sha256'],
        sha256.convert(bytes).toString());
    expect(prepared.file.bytes, isNot(same(bytes)));
  });

  test('owned cache snapshot preserves original and thumbnail blurhash',
      () async {
    final bytes = mediaTestPng();
    final prepared = await prepareContentAddressedMedia(
      file: MatrixImageFile(
          bytes: bytes,
          name: 'photo.png',
          width: 2,
          height: 3,
          blurhash: 'original-placeholder'),
      thumbnail: MatrixImageFile(
          bytes: mediaTestPng(width: 1, height: 1),
          name: 'thumb.png',
          width: 1,
          height: 1,
          blurhash: 'thumb-placeholder'),
      accountId: 'alice',
      cacheContent: (input) =>
          cacheOutgoingMedia(accountId: 'alice', roomId: 'room', bytes: input),
    );
    expect((prepared.file as MatrixImageFile).blurhash, 'original-placeholder');
    expect(prepared.thumbnail!.blurhash, 'thumb-placeholder');
    expect(prepared.file.bytes, isNot(same(bytes)));
  });

  test('transformed image does not retain its old blurhash', () async {
    final bytes = mediaTestPng(width: 4096, height: 1);
    final prepared = await prepareContentAddressedMedia(
      file: MatrixImageFile(
          bytes: bytes,
          name: 'wide.png',
          width: 4096,
          height: 1,
          blurhash: 'stale-placeholder'),
      accountId: 'alice',
      cacheContent: (input) =>
          cacheOutgoingMedia(accountId: 'alice', roomId: 'room', bytes: input),
    );
    expect((prepared.file as MatrixImageFile).width, lessThan(4096));
    expect((prepared.file as MatrixImageFile).blurhash, isNull);
  });

  test('store persists the worker snapshot even when producer mutates',
      () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    mediaDigestObserver = (_, __) => bytes[0] = 9;
    final file = await MediaCache.store('room', 'event', bytes,
        accountId: 'alice', contentSha256: sha256.convert(bytes).toString());
    expect(await file.readAsBytes(), [1, 2, 3]);
  });

  test('clear at worker completion cannot repopulate memory or disk', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    mediaDigestObserver = (_, __) => clearMediaMemoryCaches();
    await expectLater(
        MediaCache.store('room', 'event', bytes, accountId: 'alice'),
        throwsStateError);
    expect(contentMediaMemoryCache.totalBytes, 0);
    expect(
        await MediaCache.probeCachedObject('room', 'event', accountId: 'alice'),
        isNull);
  });

  test('cancel at worker completion cannot persist a late cold result',
      () async {
    final scope = MediaConsumerScope();
    mediaDigestObserver = (_, __) => scope.cancel();
    final pending = scope.run(() => loadMediaWithCache(
        const MediaCacheKey(
            accountId: 'alice', roomId: 'room', eventId: 'event'),
        () async => Uint8List.fromList([1, 2, 3])));
    await expectLater(pending, throwsA(isA<MediaLoadCanceled>()));
    expect(contentMediaMemoryCache.totalBytes, 0);
    expect(
        await MediaCache.probeCachedObject('room', 'event', accountId: 'alice'),
        isNull);
  });

  test(
      'cache cancellation and generation change hold bytes until real source settles',
      () async {
    final scope = MediaConsumerScope();
    final source = Completer<Uint8List>();
    final started = Completer<void>();
    final load = scope.run(() => loadMediaWithCache(
            const MediaCacheKey(
                accountId: 'alice', roomId: 'room', eventId: 'held'), () {
          started.complete();
          return source.future;
        }, maximumBytes: 10));
    final canceled = expectLater(load, throwsA(isA<MediaLoadCanceled>()));
    await started.future;
    expect(sharedMediaTransferBudget.activeBytes, 40);
    scope.cancel();
    clearMediaMemoryCaches();
    await canceled;
    await Future<void>.delayed(Duration.zero);
    expect(sharedMediaTransferBudget.activeBytes, 40);
    source.complete(Uint8List.fromList([1]));
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(sharedMediaTransferBudget.activeBytes, 0);
    expect(
        await MediaCache.probeCachedObject('room', 'held', accountId: 'alice'),
        isNull);
  });

  test('large transient previews are budgeted separately until verified',
      () async {
    final memory = MediaMemoryCache(
        budget: sharedMediaMemoryBudget, accountNamespace: 'alice');
    addTearDown(memory.dispose);
    final bytes = Uint8List(2 * 1024 * 1024);
    final first = memory.seedLocalPreview('first', bytes);
    final second = memory.seedLocalPreview('second', bytes);
    expect(sharedMediaMemoryBudget.totalBytes, bytes.length * 2);
    expect(memory.get('first'), isNot(same(memory.get('second'))));
    expect(await first, same(await second));
    expect(sharedMediaMemoryBudget.totalBytes, bytes.length);
  });

  test('late preview proof cannot overwrite a replacement or undo clear',
      () async {
    final memory = MediaMemoryCache(
        budget: sharedMediaMemoryBudget, accountNamespace: 'alice');
    addTearDown(memory.dispose);
    final first = memory.seedLocalPreview('event', Uint8List(2 * 1024 * 1024));
    memory.put('event', Uint8List.fromList([9]));
    expect(await first, isNull);
    expect(memory.get('event'), [9]);
    final second = memory.seedLocalPreview('other', Uint8List(2 * 1024 * 1024));
    clearMediaMemoryCaches();
    expect(await second, isNull);
    expect(memory.totalBytes, 0);
  });
}
