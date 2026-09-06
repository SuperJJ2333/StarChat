import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/video_poster_session_cache.dart';

void main() {
  test('fresh disk read waits until old write and cleanup complete', () async {
    final disk = <String, Uint8List>{};
    final entered = Completer<void>();
    final persist = Completer<void>();
    final persisted = Completer<void>();
    final finish = Completer<void>();
    var first = true;
    final cache = VideoPosterSessionCache(
      diskRead: (k) async => disk[k],
      diskWrite: (k, b) async {
        if (first) {
          first = false;
          entered.complete();
          await persist.future;
          disk[k] = b;
          persisted.complete();
          await finish.future;
        } else {
          disk[k] = b;
        }
      },
      diskDelete: (k) async {
        disk.remove(k);
      },
      diskListKeys: () async => disk.keys.toList(),
    );
    final old = cache.load('k', () async => Uint8List.fromList([1]));
    await entered.future;
    await cache.clearAll();
    persist.complete();
    await persisted.future;
    final fresh = cache.load('k', () async => Uint8List.fromList([2]));
    await Future<void>.delayed(Duration.zero);
    finish.complete();
    expect((await old).stale, isTrue);
    expect((await fresh).bytes, [2]);
    expect(disk['k'], [2]);
  });

  test('old eviction cannot delete a concurrent replacement', () async {
    final disk = <String, Uint8List>{};
    final entered = Completer<void>();
    final finish = Completer<void>();
    final cache = VideoPosterSessionCache(
      diskWrite: (k, b) async {
        disk[k] = b;
      },
      diskDelete: (k) async {
        if (k == 'k') {
          entered.complete();
          await finish.future;
        }
        disk.remove(k);
      },
    );
    final eviction = cache.evict('k');
    await entered.future;
    final replacement = cache.replace('other', 'k', Uint8List.fromList([2]));
    await Future<void>.delayed(Duration.zero);
    finish.complete();
    await eviction;
    await replacement;
    expect(disk['k'], [2]);
  });
  test('write exception after invalidation still returns stale', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final cache = VideoPosterSessionCache(diskWrite: (_, __) async {
      entered.complete();
      await release.future;
      throw FileWriteFailure();
    });
    final pending = cache.load('k', () async => Uint8List.fromList([1]));
    await entered.future;
    await cache.clearAll();
    release.complete();
    expect((await pending).stale, isTrue);
  });
  test('replacement in progress cannot resurrect after clearAll', () async {
    final disk = <String, Uint8List>{};
    final entered = Completer<void>();
    final release = Completer<void>();
    final cache = VideoPosterSessionCache(
      diskWrite: (k, b) async {
        entered.complete();
        await release.future;
        disk[k] = b;
      },
      diskDelete: (k) async {
        disk.remove(k);
      },
      diskListKeys: () async => disk.keys.toList(),
    );
    final pending = cache.replace('old', 'new', Uint8List.fromList([9]));
    await entered.future;
    await cache.clearAll();
    release.complete();
    await pending;
    expect(disk, isEmpty);
    expect(cache.memoryEntries, 0);
  });

  test('new generation does not join old in-flight loader', () async {
    final release = Completer<Uint8List?>();
    final cache = VideoPosterSessionCache();
    final old = cache.load('k', () => release.future);
    cache.clearMemory();
    final fresh = cache.load('k', () async => Uint8List.fromList([2]));
    release.complete(Uint8List.fromList([1]));
    expect((await old).stale, isTrue);
    final result = await fresh;
    expect(result.stale, isFalse);
    expect(result.bytes, [2]);
  });
}

final class FileWriteFailure implements Exception {}
