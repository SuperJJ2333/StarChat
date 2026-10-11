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
  late Directory root;
  late _HeldPaths paths;
  late PathProviderPlatform previous;
  setUp(() async {
    clearMediaMemoryCaches();
    final fixtures = await Directory(p.normalize(p.absolute(
            '../../docs/verification/artifacts/2026-10-11/im-media-cache-regression/fixtures')))
        .create(recursive: true);
    root = await fixtures.createTemp('publication-');
    previous = PathProviderPlatform.instance;
    paths = _HeldPaths(root.path);
    PathProviderPlatform.instance = paths;
  });
  tearDown(() async {
    paths.unblock();
    await _settled();
    mediaDigestObserver = null;
    clearMediaMemoryCaches();
    await MediaCache.closeQuotaIndexes();
    PathProviderPlatform.instance = previous;
    await root.delete(recursive: true);
  });

  for (final mode in ['control', 'cancel', 'rejoin']) {
    test('store root wait checks current publication demand: $mode', () async {
      final first = MediaConsumerScope();
      final next = MediaConsumerScope();
      final bytes = Uint8List.fromList([101, 102, 103]);
      final key = _key(bytes);
      var calls = 0;
      mediaDigestObserver = (_, __) => paths.hold = true;
      Future<Uint8List> load() => loadMediaWithCache(key, () async {
            calls++;
            return bytes;
          }, maximumBytes: 1024);
      Object? failure;
      final observed = first
          .run(load)
          .then<void>((_) {}, onError: (Object error) => failure = error);
      Future<Uint8List>? joined;
      try {
        await paths.blocked.future.timeout(const Duration(seconds: 5));
        expect(await File(_objectPath(root, key)).exists(), isFalse);
        if (mode != 'control') {
          first.cancel();
          await observed;
          expect(failure, isA<MediaLoadCanceled>());
          expect(mediaLoadScheduler.debugConsumerCount, 0);
          expect(sharedMediaTransferBudget.activeBytes, greaterThan(0));
        }
        if (mode == 'rejoin') {
          joined = next.run(load);
          await _waitFor(() => mediaLoadScheduler.debugConsumerCount == 1);
          expect(calls, 1);
        }
        paths.unblock();
        await observed;
        if (joined != null) expect(await joined, bytes);
        await _settled();
        final cached = await MediaCache.cached('room', 'event',
            accountId: key.accountId, contentSha256: key.contentSha256);
        if (mode == 'cancel') {
          expect(cached, isNull);
          final objects = File(_objectPath(root, key)).parent;
          if (await objects.exists()) {
            expect(await objects.list().toList(), isEmpty);
          }
        } else {
          expect(await cached!.readAsBytes(), bytes);
          expect(calls, 1);
          if (mode == 'control') expect(failure, isNull);
        }
      } finally {
        paths.unblock();
        first.cancel();
        next.cancel();
        await observed;
        if (joined != null) await joined.catchError((_) => Uint8List(0));
      }
    });
  }

  for (final target in ['object', 'reference']) {
    test('cancel after $target temp flush preserves existing publications',
        () async {
      final bytes = Uint8List.fromList([104, 105, 106]);
      final key = _key(bytes);
      final previousBytes = Uint8List.fromList([21, 22, 23]);
      final previousHash = sha256.convert(previousBytes).toString();
      final oldObject = await MediaCache.store('room', 'event', previousBytes,
          accountId: key.accountId, contentSha256: previousHash);
      final reference = File('${oldObject.parent.parent.path}/refs/'
          '${sha256.convert(utf8.encode(jsonEncode(['room', 'event'])))}.ref');
      final oldReference = await reference.readAsString();
      final objectPath = _objectPath(root, key);
      final files =
          _HeldAtomicFiles(target == 'object' ? objectPath : reference.path);
      final observer = MediaConsumerScope();
      Object? failure;
      final observed = IOOverrides.runWithIOOverrides(
          () => observer
              .run(() => loadMediaWithCache(key, () async => bytes,
                  maximumBytes: 1024))
              .then<void>((_) {}, onError: (Object error) => failure = error),
          files);
      try {
        await files.blocked.future.timeout(const Duration(seconds: 5));
        expect(await reference.readAsString(), oldReference);
        observer.cancel();
        await observed;
        expect(failure, isA<MediaLoadCanceled>());
        expect(sharedMediaTransferBudget.activeBytes, greaterThan(0));
        files.unblock();
        await _settled();
        expect(await reference.readAsString(), oldReference);
        expect(await oldObject.readAsBytes(), previousBytes);
        expect(await File(objectPath).exists(), target == 'reference',
            reason: 'An object published before cancellation remains valid; '
                'an unpublished object must not be renamed into place.');
        final leftovers = await root
            .list(recursive: true)
            .where((entry) => entry.path.endsWith('.tmp'))
            .toList();
        expect(leftovers, isEmpty);
      } finally {
        files.unblock();
        observer.cancel();
        await observed;
      }
    });
  }
}

MediaCacheKey _key(Uint8List bytes) => MediaCacheKey(
    accountId: 'synthetic-publication',
    roomId: 'room',
    eventId: 'event',
    contentSha256: sha256.convert(bytes).toString());

String _objectPath(Directory root, MediaCacheKey key) =>
    '${root.path}/chat-media/v2/${sha256.convert(utf8.encode(key.accountId))}'
    '/objects/${key.contentSha256}';

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue, reason: 'Real work did not reach its boundary');
}

Future<void> _settled() => _waitFor(() =>
    mediaLoadScheduler.debugActiveCount == 0 &&
    sharedMediaTransferBudget.activeBytes == 0);

final class _HeldPaths extends PathProviderPlatform {
  _HeldPaths(this.path);
  final String path;
  bool hold = false;
  bool held = false;
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

final class _HeldAtomicFiles extends IOOverrides {
  _HeldAtomicFiles(this.target) : previous = IOOverrides.current;
  final String target;
  final IOOverrides? previous;
  final blocked = Completer<void>();
  final release = Completer<void>();
  void unblock() {
    if (!release.isCompleted) release.complete();
  }

  @override
  File createFile(String path) {
    final file = previous?.createFile(path) ?? super.createFile(path);
    if (path.startsWith('$target.') && path.endsWith('.tmp')) {
      return _HeldFile(file, this);
    }
    return file;
  }
}

final class _HeldFile implements File {
  _HeldFile(this.file, this.owner);
  final File file;
  final _HeldAtomicFiles owner;
  @override
  Future<File> writeAsBytes(List<int> bytes,
      {FileMode mode = FileMode.write, bool flush = false}) async {
    await file.writeAsBytes(bytes, mode: mode, flush: flush);
    if (!owner.blocked.isCompleted) {
      owner.blocked.complete();
      await owner.release.future;
    }
    return this;
  }

  @override
  Future<bool> exists() => file.exists();
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);
  @override
  Future<File> rename(String path) => file.rename(path);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
