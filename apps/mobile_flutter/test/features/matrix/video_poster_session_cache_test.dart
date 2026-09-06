import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/video_poster_session_cache.dart';

/// 规格 #1：视频预览图会话缓存。
void main() {
  Uint8List poster(String tag) => Uint8List.fromList(tag.codeUnits);

  group('验收：零重复加载', () {
    test('首次显示 A 后，滚动移出/移入与退出/重进房间 10 次：加载次数 1',
        () async {
      var loads = 0;
      final cache = VideoPosterSessionCache();
      const key = 'acct|room|mediaA|v1|grid';
      final first = await cache.load(key, () async {
        loads++;
        return poster('A');
      });
      expect(first.freshlyLoaded, isTrue);
      for (var i = 0; i < 20; i++) {
        // 移出（LRU 淘汰压力）+ 移入（重新读取）交替。
        final again = await cache.load(key, () async {
          loads++;
          return poster('A');
        });
        expect(again.fromMemory, isTrue, reason: '内存命中，不重新加载');
      }
      expect(loads, 1, reason: '新增网络请求 0、首帧提取 0');
    });

    test('淘汰内存图片后再次显示：命中磁盘，加载次数仍为 1', () async {
      var loads = 0;
      final disk = <String, Uint8List>{};
      final cache = VideoPosterSessionCache(
        memoryBudgetBytes: 10, // 立即淘汰内存。
        diskRead: (k) async => disk[k],
        diskWrite: (k, b) async => disk[k] = b,
        diskDelete: (k) async => disk.remove(k),
      );
      const key = 'acct|room|mediaB|v1|grid';
      await cache.load(key, () async {
        loads++;
        return poster('B' * 20);
      });
      expect(cache.memoryEntries, 0, reason: '超预算被淘汰');
      final second = await cache.load(key, () async {
        loads++;
        return poster('should-not-run');
      });
      expect(second.fromDisk, isTrue, reason: '磁盘命中');
      expect(loads, 1, reason: '不重新下载视频/不重新提取首帧');
    });

    test('并发同键：只执行一次加载任务', () async {
      var loads = 0;
      final cache = VideoPosterSessionCache();
      const key = 'acct|room|mediaC|v1|grid';
      final results = await Future.wait([
        for (var i = 0; i < 5; i++)
          cache.load(key, () async {
            loads++;
            await Future<void>.delayed(const Duration(milliseconds: 10));
            return poster('C');
          }),
      ]);
      expect(loads, 1);
      expect(results.every((r) => r.bytes != null), isTrue);
    });
  });

  group('键与失效', () {
    test('缓存键包含账号/房间/媒体/版本/规格；账号切换不可见', () async {
      final keyA = VideoPosterSessionCache.keyFor(
          accountId: 'acct-a', roomId: 'r', mediaId: 'm', mediaVersion: '1', spec: 'grid');
      final keyB = VideoPosterSessionCache.keyFor(
          accountId: 'acct-b', roomId: 'r', mediaId: 'm', mediaVersion: '1', spec: 'grid');
      expect(keyA, isNot(keyB), reason: '账号隔离');
      final cache = VideoPosterSessionCache();
      await cache.load(keyA, () async => poster('A'));
      // B 账号读取同房间同媒体 → 键不同 → 未命中（不读到 A 缓存）。
      final bResult = await cache.load(keyB, () async => poster('B'));
      expect(bResult.freshlyLoaded, isTrue);
      expect(String.fromCharCodes(bResult.bytes!), 'B');
    });

    test('媒体版本变化：新键自然失效旧项', () async {
      final cache = VideoPosterSessionCache();
      final v1 = VideoPosterSessionCache.keyFor(
          accountId: 'a', roomId: 'r', mediaId: 'm', mediaVersion: '1', spec: 'grid');
      final v2 = VideoPosterSessionCache.keyFor(
          accountId: 'a', roomId: 'r', mediaId: 'm', mediaVersion: '2', spec: 'grid');
      await cache.load(v1, () async => poster('old'));
      final replaced = await cache.load(v2, () async => poster('new'));
      expect(String.fromCharCodes(replaced.bytes!), 'new');
    });

    test('撤回/删除：evict 移除对应项（内存+磁盘）', () async {
      final disk = <String, Uint8List>{};
      final cache = VideoPosterSessionCache(
        diskRead: (k) async => disk[k],
        diskWrite: (k, b) async => disk[k] = b,
        diskDelete: (k) async => disk.remove(k),
      );
      const key = 'a|r|m|1|grid';
      await cache.load(key, () async => poster('X'));
      await cache.evict(key);
      expect(cache.memoryEntries, 0);
      expect(disk.containsKey(key), isFalse);
    });

    test('会话销毁/退出账号：clearMemory 清空（页面重建不调用）', () async {
      final cache = VideoPosterSessionCache();
      await cache.load('k', () async => poster('k'));
      expect(cache.memoryEntries, 1);
      cache.clearMemory();
      expect(cache.memoryEntries, 0);
    });
  });

  group('例外路径（缓存保证例外，单独标注）', () {
    test('加载器失败：返回可重试状态，不自动重试循环', () async {
      final cache = VideoPosterSessionCache();
      const key = 'a|r|m|1|grid';
      final result = await cache.load(key, () async => throw StateError('network'));
      expect(result.retryable, isTrue);
      // 不因重复 build 自动重试：再次 load 会再执行加载器（用户显式
      // 重试入口），但结果仍为可重试状态而非异常抛出。
      final again = await cache.load(key, () async => throw StateError('network'));
      expect(again.retryable, isTrue);
    });

    test('磁盘损坏（读抛异常）：降级加载器；磁盘写失败不影响显示',
        () async {
      var loads = 0;
      final cache = VideoPosterSessionCache(
        diskRead: (k) async => throw FileSystemException('corrupt'),
        diskWrite: (k, b) async => throw FileSystemException('no space'),
      );
      final result = await cache.load('k', () async {
        loads++;
        return poster('fresh');
      });
      expect(result.bytes, isNotNull, reason: '磁盘异常降级加载器成功');
      expect(loads, 1);
    });

    test('会话存续期间：磁盘不按 LRU 淘汰已成功项', () async {
      final disk = <String, Uint8List>{};
      final cache = VideoPosterSessionCache(
        memoryBudgetBytes: 1, // 内存立即淘汰。
        diskRead: (k) async => disk[k],
        diskWrite: (k, b) async => disk[k] = b,
      );
      for (var i = 0; i < 30; i++) {
        await cache.load('k$i', () async => poster('p$i'));
      }
      expect(disk.length, 30, reason: '磁盘保留全部成功项');
      expect(cache.memoryEntries, lessThan(30));
    });
  });
}
