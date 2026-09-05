import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final Directory root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root.path;
}

Directory _scratch(String name) {
  final dir = Directory.systemTemp.createTempSync('media-cache-$name');
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir;
}

void main() {
  setUp(() {
    PathProviderPlatform.instance = _FakePathProvider(_scratch('setup'));
  });

  test('首次：解密一次并落盘，返回内容一致的文件', () async {
    final docs = Directory.systemTemp.createTempSync('mc-first');
    addTearDown(() => docs.deleteSync(recursive: true));
    PathProviderPlatform.instance = _FakePathProvider(docs);
    final payload = Uint8List.fromList(List.filled(1024, 7));
    var decryptions = 0;

    final file = await resolveCachedVideoFile(
      key: const MediaCacheKey(roomId: '!r1:x', eventId: '\$e1'),
      decrypt: () async {
        decryptions++;
        return payload;
      },
      memoryCache: MediaMemoryCache(),
    );

    expect(decryptions, 1);
    expect(await file.exists(), isTrue);
    expect(await file.readAsBytes(), payload);
  });

  test('二次打开（模拟重启内存缓存为空）：零解密直读磁盘缓存', () async {
    final docs = Directory.systemTemp.createTempSync('mc-second');
    addTearDown(() => docs.deleteSync(recursive: true));
    PathProviderPlatform.instance = _FakePathProvider(docs);
    const key = MediaCacheKey(roomId: '!r1:x', eventId: '\$e2');
    var decryptions = 0;
    Future<Uint8List> decrypt() async {
      decryptions++;
      return Uint8List.fromList([1, 2, 3]);
    }

    final first = await resolveCachedVideoFile(
        key: key, decrypt: decrypt, memoryCache: MediaMemoryCache());
    // 模拟进程重启：新内存缓存、再开一次。
    final second = await resolveCachedVideoFile(
        key: key, decrypt: decrypt, memoryCache: MediaMemoryCache());

    expect(decryptions, 1, reason: '第二次打开不得重复下载解密');
    expect(second.path, first.path, reason: '命中同一缓存文件');
  });

  test('并发双击合并为一次下载（在途去重）', () async {
    final docs = Directory.systemTemp.createTempSync('mc-conc');
    addTearDown(() => docs.deleteSync(recursive: true));
    PathProviderPlatform.instance = _FakePathProvider(docs);
    final memory = MediaMemoryCache();
    var decryptions = 0;

    final results = await Future.wait([
      resolveCachedVideoFile(
        key: const MediaCacheKey(roomId: '!r1:x', eventId: '\$e3'),
        decrypt: () async {
          decryptions++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return Uint8List.fromList([9, 9]);
        },
        memoryCache: memory,
      ),
      resolveCachedVideoFile(
        key: const MediaCacheKey(roomId: '!r1:x', eventId: '\$e3'),
        decrypt: () async {
          decryptions++;
          return Uint8List.fromList([9, 9]);
        },
        memoryCache: memory,
      ),
    ]);

    expect(decryptions, 1, reason: '并发打开同一视频必须共享在途下载');
    expect(results[0].path, results[1].path);
  });

  test('不同事件不串缓存（roomId+eventId 键控）', () async {
    final docs = Directory.systemTemp.createTempSync('mc-keys');
    addTearDown(() => docs.deleteSync(recursive: true));
    PathProviderPlatform.instance = _FakePathProvider(docs);

    final a = await resolveCachedVideoFile(
      key: const MediaCacheKey(roomId: '!r1:x', eventId: '\$same'),
      decrypt: () async => Uint8List.fromList([1]),
      memoryCache: MediaMemoryCache(),
    );
    final b = await resolveCachedVideoFile(
      key: const MediaCacheKey(roomId: '!r2:x', eventId: '\$same'),
      decrypt: () async => Uint8List.fromList([2]),
      memoryCache: MediaMemoryCache(),
    );

    expect(await a.readAsBytes(), [1]);
    expect(await b.readAsBytes(), [2]);
  });

  test('VideoViewerPage 不再写系统临时目录（源码防回归）', () {
    final source = File('lib/ui/chat/wechat_video_message.dart')
        .readAsStringSync();
    final start = source.indexOf('Future<bool> _initialize()');
    final end = source.indexOf('  }', start);
    final body = source.substring(start, end);
    expect(body.contains('Directory.systemTemp'), isFalse,
        reason: '播放器直接使用缓存文件，不再每次写临时文件且不清理');
    expect(body.contains('loadFile'), isTrue,
        reason: '播放文件由外部解析（磁盘缓存优先）');
  });
// ── M03：原子写 + 损坏检测 + 写入合并 ──────────────────────────

test('M03：半写入（截断）文件被判定损坏 → 删除后未命中并重新解密', () async {
  final docs = _scratch('m03-corrupt');
  PathProviderPlatform.instance = _FakePathProvider(docs);
  final payload = Uint8List.fromList(List.filled(500, 3));
  var decryptions = 0;
  Future<Uint8List> decrypt() async {
    decryptions++;
    return payload;
  }

  const key = MediaCacheKey(roomId: '!m03:x', eventId: '\$m03-e1');
  // 正常写入一次。
  final first = await MediaCache.store(key.roomId, key.eventId, payload);
  expect(await first.length(), 500);
  // 半写入模拟：截断数据文件（元数据仍声明 500）。
  await first.writeAsBytes(payload.sublist(0, 120), flush: true);
  // cached() 必须判损坏 → 删除 → 未命中。
  expect(await MediaCache.cached(key.roomId, key.eventId), isNull,
      reason: '长度与元数据不符 = 损坏，不得当作命中');
  // 重新走 loadMediaWithCache：再解密一次并修复缓存。
  final repaired = await loadMediaWithCache(key, decrypt);
  expect(repaired.length, 500);
  expect(decryptions, 1, reason: '损坏后仅重新解密一次（修复闭环）');
  final cachedAgain = await MediaCache.cached(key.roomId, key.eventId);
  expect(cachedAgain, isNotNull);
  expect(await cachedAgain!.length(), 500);
});

test('M03：进程中止留下空文件 + 孤儿元数据 → 未命中可恢复', () async {
  final docs = _scratch('m03-empty');
  PathProviderPlatform.instance = _FakePathProvider(docs);
  // 直接构造"空数据 + 声明 10 字节"的残留（写一半进程被杀）。
  final file = await MediaCache.store(
      '!m03b:x', '\$e-empty', Uint8List.fromList(List.filled(10, 1)));
  await file.writeAsBytes(const [], flush: true); // 截断为 0 字节。
  expect(await MediaCache.cached('!m03b:x', '\$e-empty'), isNull,
      reason: '空文件判损坏（长度不符）');
});

test('M03：同键并发写共享一次落盘（写入合并）', () async {
  final docs = _scratch('m03-merge');
  PathProviderPlatform.instance = _FakePathProvider(docs);
  final payloadA = Uint8List.fromList(List.filled(64, 9));
  final payloadB = Uint8List.fromList(List.filled(64, 9));
  final files = await Future.wait([
    MediaCache.store('!m03c:x', '\$e-merge', payloadA),
    MediaCache.store('!m03c:x', '\$e-merge', payloadB),
  ]);
  // 合并写入：两个调用者拿到同一文件对象语义（同一路径），内容完整。
  expect(files[0].path, files[1].path);
  expect(await files[0].length(), 64);
  expect(await MediaCache.cached('!m03c:x', '\$e-merge'), isNotNull);
});
}
