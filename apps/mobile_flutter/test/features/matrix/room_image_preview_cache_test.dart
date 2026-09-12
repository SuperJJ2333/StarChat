import 'dart:typed_data';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/emoji_preview_cache.dart';
import 'package:liuhetong_mobile/features/matrix/room_image_preview_cache.dart';
import 'package:liuhetong_mobile/features/matrix/media_memory_budget.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';

void main() {
  test('preview disk identity can differ while account memory stays canonical',
      () {
    final images = MediaMemoryCache(
        budget: sharedMediaMemoryBudget, accountNamespace: '@a:test');
    final preview = RoomImagePreviewCache(
        accountId: 'https://test|@a:test',
        memoryNamespace: '@a:test',
        roomId: 'r',
        read: (_) async => null,
        write: (_, __) async {});
    final first = images.put('image', Uint8List.fromList([1, 2]));
    preview.seed('event', Uint8List.fromList([1, 2]));
    expect(preview.get('event'), same(first));
    preview.dispose();
    images.dispose();
  });

  test('clear while probing disk cannot continue into a source load', () async {
    final disk = Completer<Uint8List?>();
    var sources = 0;
    final cache = RoomImagePreviewCache(
        accountId: 'a',
        roomId: 'r',
        read: (_) => disk.future,
        write: (_, __) async {});
    final loading = cache.load('event', () async {
      sources++;
      return Uint8List(1);
    });
    final assertion = expectLater(loading, throwsStateError);
    sharedMediaMemoryBudget.clear();
    disk.complete(null);
    await assertion;
    expect(sources, 0);
    cache.dispose();
  });
  test('global clear invalidates a pending preview disk probe', () async {
    final disk = Completer<Uint8List?>();
    final cache = RoomImagePreviewCache(
        accountId: 'a',
        roomId: 'r',
        read: (_) => disk.future,
        write: (_, __) async {});
    final loading = cache.readCached('event');
    sharedMediaMemoryBudget.clear();
    disk.complete(Uint8List.fromList([1]));
    expect(await loading, isNull);
    expect(cache.get('event'), isNull);
    cache.dispose();
  });
  test('cache-only disk probe deduplicates and populates synchronous memory',
      () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    var reads = 0;
    final cache = RoomImagePreviewCache(
        accountId: 'a',
        roomId: 'r',
        read: (_) async {
          reads++;
          return bytes;
        },
        write: (_, __) async {});
    final results = await Future.wait(
        [cache.readCached('event'), cache.readCached('event')]);
    expect(results, [bytes, bytes]);
    expect(reads, 1);
    expect(cache.get('event'), same(results.first));
    expect(() => results.first![0] = 9, throwsUnsupportedError);
    expect(
        await cache.load(
            'event', () async => throw StateError('must not load source')),
        same(results.first));
    cache.dispose();
  });

  test('oversized bytes never exceed the encrypted disk quota', () async {
    var writes = 0;
    final cache = RoomImagePreviewCache(
        accountId: 'a',
        roomId: 'r',
        read: (_) async => null,
        write: (_, __) async {
          writes++;
        });
    final oversized = Uint8List(64 * 1024 * 1024);
    cache.seed('local', oversized);
    await cache.load('remote', () async => oversized);
    expect(writes, 0,
        reason:
            'AES-GCM adds 28 bytes, so the plaintext limit is below 64 MiB');
    cache.dispose();
  });

  test(
      'local seed is synchronous and bounded without replacing an active source flight',
      () async {
    final pending = Completer<Uint8List>();
    final cache = RoomImagePreviewCache(
        accountId: 'a',
        roomId: 'r',
        maxEntries: 1,
        read: (_) async => null,
        write: (_, __) async {});
    final flight = cache.load('tx', () => pending.future);
    await Future<void>.delayed(Duration.zero);
    final local = Uint8List.fromList([1]);
    cache.seed('tx', local);
    expect(cache.get('tx'), local);
    local[0] = 9;
    expect(cache.get('tx'), [1]);
    cache.seed('next', Uint8List.fromList([2]));
    expect(cache.get('tx'), isNull);
    expect(cache.load('tx', () async => throw StateError('duplicate source')),
        same(flight));
    pending.complete(Uint8List.fromList([3]));
    expect(await flight, [3]);
    expect(cache.get('tx'), [3]);
    cache.dispose();
  });

  test('encrypted local preview survives reopen without plaintext disk data',
      () async {
    final root = Directory(
        '${Directory.current.path}/../../docs/verification/artifacts/2026-09-11/performance/encrypted-preview-store');
    final keys = _Keys();
    final store = EncryptedEmojiPreviewStore('test-room-image-account',
        keys: keys, directory: () async => root);
    final preview = Uint8List.fromList(List.generate(128, (i) => i));
    final first = RoomImagePreviewCache(
        accountId: 'alice',
        roomId: 'room',
        read: store.read,
        write: store.write);
    await first.load('image', () async => preview);
    first.dispose();
    final reopenedStore = EncryptedEmojiPreviewStore('test-room-image-account',
        keys: keys, directory: () async => root);
    final reopened = RoomImagePreviewCache(
        accountId: 'alice',
        roomId: 'room',
        read: reopenedStore.read,
        write: reopenedStore.write);
    expect(
        await reopened.load(
            'image', () async => throw StateError('must not request network')),
        preview);
    final files = await root
        .list(recursive: true)
        .where((e) => e is File && e.path.endsWith('.bin'))
        .cast<File>()
        .toList();
    expect(files, isNotEmpty);
    for (final file in files) {
      expect(await file.readAsBytes(), isNot(equals(preview)));
    }
    final other = RoomImagePreviewCache(
        accountId: 'bob',
        roomId: 'room',
        read: reopenedStore.read,
        write: reopenedStore.write);
    expect(await other.load('image', () async => Uint8List.fromList([9])), [9]);
    reopened.dispose();
    other.dispose();
  });

  test('session preview pool keeps encoded bytes for a same-account reentry',
      () {
    addTearDown(RoomImagePreviewCache.clearSessionMemory);
    final first = RoomImagePreviewCache.forRoomSession(
        accountId: 'alice', roomId: 'room');
    final bytes = Uint8List.fromList([1, 2, 3]);
    first.seed('image', bytes);
    first.dispose();

    final reopened = RoomImagePreviewCache.forRoomSession(
        accountId: 'alice', roomId: 'room');
    expect(reopened.get('image'), bytes);
    RoomImagePreviewCache.clearSessionMemory();
    expect(reopened.get('image'), isNull);
    reopened.dispose();
  });

  test('session preview pool is account scoped and clearable', () {
    addTearDown(RoomImagePreviewCache.clearSessionMemory);
    final alice = RoomImagePreviewCache.forRoomSession(
        accountId: 'alice', roomId: 'room');
    alice.seed('image', Uint8List.fromList([1, 2, 3]));
    final bob =
        RoomImagePreviewCache.forRoomSession(accountId: 'bob', roomId: 'room');
    expect(bob.get('image'), isNull);
    RoomImagePreviewCache.clearSessionMemory();
    alice.dispose();
    final aliceReentry = RoomImagePreviewCache.forRoomSession(
        accountId: 'alice', roomId: 'room');
    expect(aliceReentry.get('image'), isNull);
    aliceReentry.dispose();
    bob.dispose();
  });

  test('session preview pool includes room in its bounded key', () {
    addTearDown(RoomImagePreviewCache.clearSessionMemory);
    final roomA = RoomImagePreviewCache.forRoomSession(
        accountId: 'alice', roomId: 'room-a');
    roomA.seed('image', Uint8List.fromList([1, 2, 3]));
    final roomB = RoomImagePreviewCache.forRoomSession(
        accountId: 'alice', roomId: 'room-b');
    expect(roomB.get('image'), isNull);
    roomA.dispose();
    roomB.dispose();
  });

  test('disposed reentry never joins an earlier page pending load', () async {
    addTearDown(RoomImagePreviewCache.clearSessionMemory);
    final heldRead = Completer<Uint8List?>();
    final first = RoomImagePreviewCache.forRoomSession(
        accountId: 'alice', roomId: 'room', read: (_) => heldRead.future);
    final pending = first.load('image', () async => Uint8List.fromList([1]));
    first.dispose();
    final reopened = RoomImagePreviewCache.forRoomSession(
        accountId: 'alice',
        roomId: 'room',
        read: (_) async => Uint8List.fromList([2, 3]));
    expect(await reopened.load('image', () async => throw StateError('source')),
        [2, 3]);
    heldRead.complete(Uint8List.fromList([9]));
    await expectLater(pending, throwsStateError);
    expect(reopened.get('image'), [2, 3]);
    reopened.dispose();
  });

  test(
      'persistent writes serialize across room instances for secure key initialization',
      () async {
    var active = 0;
    var peak = 0;
    Future<void> write(String _, Uint8List bytes) async {
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(Duration.zero);
      active--;
    }

    final a = RoomImagePreviewCache(
        accountId: 'a', roomId: 'one', read: (_) async => null, write: write);
    final b = RoomImagePreviewCache(
        accountId: 'a', roomId: 'two', read: (_) async => null, write: write);
    await Future.wait([
      a.load('e', () async => Uint8List(1)),
      b.load('e', () async => Uint8List(1))
    ]);
    expect(peak, 1);
  });

  test('concurrent requests share source and disposed sessions cannot publish',
      () async {
    final pending = Completer<Uint8List>();
    var requests = 0;
    var writes = 0;
    final cache = RoomImagePreviewCache(
        accountId: 'a',
        roomId: 'r',
        read: (_) async => null,
        write: (_, __) async {
          writes++;
        });
    Future<Uint8List> source() {
      requests++;
      return pending.future;
    }

    final first = cache.load('event', source);
    final second = cache.load('event', source);
    expect(identical(first, second), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1);
    cache.dispose();
    final assertion = expectLater(first, throwsStateError);
    pending.complete(Uint8List.fromList([1]));
    await assertion;
    expect(cache.get('event'), isNull);
    expect(writes, 0);
  });

  test('evicted previews reload locally without a source request', () async {
    final disk = <String, Uint8List>{};
    final cache = RoomImagePreviewCache(
        accountId: 'alice',
        roomId: 'room',
        maxEntries: 1,
        read: (key) async => disk[key],
        write: (key, bytes) async {
          disk[key] = bytes;
        });
    var requests = 0;
    Future<Uint8List> load() async {
      requests++;
      return Uint8List.fromList([71, 73, 70, 56, 57, 97]);
    }

    final first = await cache.load('first', load);
    expect(cache.get('first'), same(first));
    await cache.load('second', load);
    expect(cache.get('first'), isNull);
    expect(await cache.load('first', load), first);
    expect(requests, 2);
  });

  test('account and room are included in persistent keys', () async {
    final disk = <String, Uint8List>{};
    RoomImagePreviewCache cache(String account, String room) =>
        RoomImagePreviewCache(
            accountId: account,
            roomId: room,
            read: (key) async => disk[key],
            write: (key, bytes) async {
              disk[key] = bytes;
            });
    await cache('alice', 'room')
        .load('same', () async => Uint8List.fromList([1]));
    expect(
        await cache('bob', 'room')
            .load('same', () async => Uint8List.fromList([2])),
        [2]);
    expect(
        await cache('alice', 'other')
            .load('same', () async => Uint8List.fromList([3])),
        [3]);
    expect(disk.length, 3);
  });
}

final class _Keys implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
