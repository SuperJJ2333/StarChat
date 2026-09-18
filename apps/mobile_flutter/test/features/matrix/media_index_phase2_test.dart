import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache_metrics.dart';
import 'package:liuhetong_mobile/features/matrix/media_index.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Phase 2 验收：本地媒体索引 / 两级配额 / LRU / 引用保护 / GC /
/// 崩溃恢复 / 并发 / 跨域共享 / 指标与脱敏。
class _Paths extends PathProviderPlatform {
  _Paths(this.documents, this.support);
  final String documents;
  final String support;
  @override
  Future<String?> getApplicationDocumentsPath() async => documents;
  @override
  Future<String?> getApplicationSupportPath() async => support;
}

/// 500MB 全零内容的 sha256（分块计算，避免一次性分配 500MB 内存）。
String _sha256OfZeros(int totalBytes) {
  final digests = <Digest>[];
  final input = sha256.startChunkedConversion(_DigestSink(digests));
  final chunk = Uint8List(1024 * 1024);
  var written = 0;
  while (written < totalBytes) {
    final size = (totalBytes - written).clamp(0, chunk.length);
    input.add(size == chunk.length ? chunk : Uint8List(size));
    written += size;
  }
  input.close();
  return digests.single.toString();
}

final class _DigestSink implements Sink<Digest> {
  _DigestSink(this.digests);
  final List<Digest> digests;
  @override
  void add(Digest data) => digests.add(data);
  @override
  void close() {}
}

Uint8List _bytes(int seed, int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (seed + i) % 256));

Future<File> _objectFile(String documents, String accountId, String name) async {
  final namespace = sha256.convert(utf8.encode(accountId)).toString();
  final dir = Directory('$documents/chat-media/v2/$namespace/objects');
  await dir.create(recursive: true);
  return File('${dir.path}/$name');
}

Future<File> _refFile(String documents, String accountId, String roomId,
    String eventId) async {
  final namespace = sha256.convert(utf8.encode(accountId)).toString();
  final dir = Directory('$documents/chat-media/v2/$namespace/refs');
  await dir.create(recursive: true);
  final digest =
      sha256.convert(utf8.encode(jsonEncode([roomId, eventId]))).toString();
  return File('${dir.path}/$digest.ref');
}

Future<int> _countFiles(String documents, String accountId, String folder) async {
  final namespace = sha256.convert(utf8.encode(accountId)).toString();
  final dir = Directory('$documents/chat-media/v2/$namespace/$folder');
  if (!await dir.exists()) return 0;
  var count = 0;
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.last;
    if (name.endsWith('.len') || name.endsWith('.tmp')) continue;
    count++;
  }
  return count;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory root;
  late String documents;

  setUp(() async {
    MediaCacheMetrics.reset();
    MediaCache.resetQuotaPolicy();
    MediaCache.clearPinsForTest();
    clearMediaMemoryCaches();
    // 绝对路径：sqflite 的 FFI 工厂对相对路径不可靠（数据库可能落到
    // 意料之外的位置），这里统一用绝对路径。
    final base = Directory(
        '${Directory.current.path}/../../docs/verification/artifacts/2026-09-17');
    await base.create(recursive: true);
    root = await base.createTemp('phase2-');
    documents = '${root.path}/docs';
    final support = '${root.path}/support';
    await Directory(documents).create(recursive: true);
    await Directory(support).create(recursive: true);
    PathProviderPlatform.instance = _Paths(documents, support);
    final index = MediaIndex(
      databasePath: '$support/index.db',
      factory: databaseFactoryFfiNoIsolate,
    );
    index.resetForTest();
    MediaIndex.overrideShared(index);
    addTearDown(() async {
      await MediaIndex.shared.close();
      MediaIndex.overrideShared(null);
    });
  });

  tearDown(() async {
    MediaCache.resetQuotaPolicy();
    MediaCache.useCheapPathMinBytesForTest(null);
    MediaCache.clearPinsForTest();
    clearMediaMemoryCaches();
    MediaCacheMetrics.reset();
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('P0-1：大文件缓存命中不再重算 SHA-256', () {
    test('500MB 对象：首次完整校验一次，之后命中 0 全文件哈希', () async {
      const size = 500 * 1024 * 1024;
      final hash = _sha256OfZeros(size);
      final object = await _objectFile(documents, 'alice', hash);
      // 稀疏文件：500MB 逻辑大小，不实际占用磁盘。
      final handle = await object.open(mode: FileMode.write);
      await handle.truncate(size);
      await handle.close();
      await File('${object.path}.len').writeAsString('$size');
      await (await _refFile(documents, 'alice', 'room-1', 'event-1'))
          .writeAsString(hash);

      // 首次：索引缺失 → legacy 完整校验（允许一次整文件哈希）。
      final first = await MediaCache.cached('room-1', 'event-1',
          accountId: 'alice');
      expect(first, isNotNull);
      expect(await first!.length(), size);
      final hashAfterFirst = MediaCacheMetrics.hashBytesRead;
      expect(hashAfterFirst, size, reason: '首次访问做一次完整校验（并回填索引）');
      expect(MediaCacheMetrics.hashFilesVerified, 1);

      // 第二次：索引命中 → 廉价校验，**0 新增哈希字节**。
      final second = await MediaCache.cached('room-1', 'event-1',
          accountId: 'alice');
      expect(second!.path, first.path);
      expect(MediaCacheMetrics.hashBytesRead, hashAfterFirst,
          reason: '第二次命中不得再读整个文件做 SHA-256');
      expect(MediaCacheMetrics.indexHits, greaterThan(0));

      // 第三次：按内容摘要寻址同样走索引。
      final third = await MediaCache.cached('room-2', 'event-2',
          accountId: 'alice', contentSha256: hash);
      expect(third!.path, first.path);
      expect(MediaCacheMetrics.hashBytesRead, hashAfterFirst,
          reason: 'contentSha256 寻址命中同样不得重算哈希');
      expect(MediaCacheMetrics.indexHits, greaterThan(1));
    });

    test('命中某对象不会扫描/校验同账号的其它对象（无启动全量扫描）', () async {
      MediaCache.useCheapPathMinBytesForTest(0);
      final payload = _bytes(3, 4096);
      await MediaCache.store('room-1', 'event-1', payload, accountId: 'alice');
      // 放一个同样巨大的"未索引"邻居对象：命中 event-1 时不得触碰它。
      const bigSize = 64 * 1024 * 1024;
      final bigHash = _sha256OfZeros(bigSize);
      final big = await _objectFile(documents, 'alice', bigHash);
      final handle = await big.open(mode: FileMode.write);
      await handle.truncate(bigSize);
      await handle.close();
      await File('${big.path}.len').writeAsString('$bigSize');

      MediaCacheMetrics.reset();
      final hit = await MediaCache.cached('room-1', 'event-1',
          accountId: 'alice');
      expect(hit, isNotNull);
      expect(MediaCacheMetrics.hashBytesRead, 0,
          reason: '索引命中既不算自己的哈希，也不得扫描邻居对象');
    });

    test('小对象（< 1 MiB）命中仍做完整校验：同尺寸原地篡改必被发现', () async {
      // 廉价路径的收益只在大文件上；小对象哈希成本可忽略，因此默认阈值
      // 下必须回到 Phase 1 的严格校验，不能因为索引行存在就放行。
      final payload = _bytes(5, 4096);
      final file =
          await MediaCache.store('room-1', 'event-1', payload, accountId: 'alice');
      await MediaCache.cached('room-1', 'event-1', accountId: 'alice');
      final verified = await MediaCache.cached('room-1', 'event-1',
          accountId: 'alice');
      expect(verified!.path, file.path);
      MediaCacheMetrics.reset();
      final hit = await MediaCache.cached('room-1', 'event-1',
          accountId: 'alice');
      expect(hit, isNotNull);
      expect(MediaCacheMetrics.hashBytesRead, payload.length,
          reason: '小对象索引命中仍整文件校验');

      final tampered = Uint8List.fromList(payload)..[0] = payload[0] ^ 0xff;
      await file.writeAsBytes(tampered);
      expect(
          await MediaCache.cached('room-1', 'event-1', accountId: 'alice'),
          isNull,
          reason: '同尺寸篡改在小对象上必须被完整校验发现');
    });
  });

  group('去重与变体', () {
    test('同字节两个房间：1 个对象 + 2 个引用', () async {
      final payload = _bytes(7, 8192);
      await MediaCache.store('room-a', 'event-a', payload, accountId: 'alice');
      await MediaCache.store('room-b', 'event-b', payload, accountId: 'alice');

      expect(await _countFiles(documents, 'alice', 'objects'), 1,
          reason: '同字节只允许一个物理对象');
      expect(await _countFiles(documents, 'alice', 'refs'), 2,
          reason: '两个逻辑引用各一行');
      final a = await MediaCache.cached('room-a', 'event-a', accountId: 'alice');
      final b = await MediaCache.cached('room-b', 'event-b', accountId: 'alice');
      expect(a!.path, b!.path);
    });

    test('不同压缩版本（q80/q70）字节不同：2 个对象，且媒体族只是 metadata 关联',
        () async {
      final q80 = _bytes(11, 4096);
      final q70 = _bytes(23, 4096);
      const family = 'family-body-hash';
      await MediaCache.store('room-1', 'event-q80', q80,
          accountId: 'alice',
          variant: MediaVariantKind.body,
          familyId: family);
      await MediaCache.store('room-1', 'event-q70', q70,
          accountId: 'alice',
          variant: MediaVariantKind.preview,
          familyId: family);

      expect(await _countFiles(documents, 'alice', 'objects'), 2,
          reason: '不同字节就是不同对象，不得错误合并');
      final entries =
          await MediaIndex.shared.entriesForAccount('alice');
      final families = {
        for (final entry in entries)
          if (entry.familyId != null) entry.familyId!
      };
      expect(families, {family}, reason: '媒体族只建立 metadata 关联');
      final variants = {
        for (final entry in entries) entry.variant
      };
      expect(variants.contains(MediaVariantKind.body), isTrue);
      expect(variants.contains(MediaVariantKind.preview), isTrue);
    });

    test('聊天与朋友圈同字节：1 个对象 + 2 个引用；不同字节则 2 个对象', () async {
      final shared = _bytes(31, 3072);
      await MediaCache.store('room-1', 'event-1', shared, accountId: 'alice');
      await MediaCache.store('moments', 'moment-1', shared,
          accountId: 'alice', variant: MediaVariantKind.body);
      expect(await _countFiles(documents, 'alice', 'objects'), 1);
      expect(await _countFiles(documents, 'alice', 'refs'), 2);

      // 远端演绎版不同（服务端下发的字节不同）→ 明确允许 2 个对象。
      await MediaCache.store('moments', 'moment-2', _bytes(99, 3072),
          accountId: 'alice', variant: MediaVariantKind.body);
      expect(await _countFiles(documents, 'alice', 'objects'), 2,
          reason: '字节不同就是两份对象（不是重复存储 bug）');
    });
  });

  group('账号隔离与两级配额', () {
    test('账号 A 触发淘汰不会影响账号 B（设备硬上限未达）', () async {
      MediaCache.useQuotaForTest(accountSoft: 300, deviceHard: 100000);
      // B 先写入（更旧，若是全局 LRU 会被优先淘汰）。
      await MediaCache.store('room-b', 'event-b', _bytes(1, 100),
          accountId: 'bob');
      // A 写满并超出自己的软配额。
      await MediaCache.store('room-a', 'event-a1', _bytes(2, 100),
          accountId: 'alice');
      await MediaCache.store('room-a', 'event-a2', _bytes(3, 100),
          accountId: 'alice');
      await MediaCache.store('room-a', 'event-a3', _bytes(4, 100),
          accountId: 'alice');
      await MediaCache.store('room-a', 'event-a4', _bytes(5, 100),
          accountId: 'alice');

      expect(await _countFiles(documents, 'bob', 'objects'), 1,
          reason: 'B 的缓存必须存活（配额按账号隔离）');
      final b = await MediaCache.cached('room-b', 'event-b', accountId: 'bob');
      expect(b, isNotNull, reason: 'B 的对象仍可读');
      final aCount = await _countFiles(documents, 'alice', 'objects');
      expect(aCount, lessThanOrEqualTo(3),
          reason: 'A 只在自身软配额内保留（300 字节 ≈ 3 个 100 字节对象）');
    });

    test('设备硬上限是唯一会跨账号淘汰的场景', () async {
      MediaCache.useQuotaForTest(accountSoft: 5000, deviceHard: 250);
      await MediaCache.store('room-b', 'event-b', _bytes(1, 100),
          accountId: 'bob');
      await MediaCache.store('room-a', 'event-a1', _bytes(2, 100),
          accountId: 'alice');
      await MediaCache.store('room-a', 'event-a2', _bytes(3, 100),
          accountId: 'alice');
      await MediaCache.store('room-a', 'event-a3', _bytes(4, 100),
          accountId: 'alice');

      final total = await _countFiles(documents, 'alice', 'objects') +
          await _countFiles(documents, 'bob', 'objects');
      expect(total, lessThanOrEqualTo(2),
          reason: '超过设备硬上限时按全局 LRU 兜底淘汰到上限以内');
    });
  });

  group('LRU 与访问时间', () {
    test('访问过的对象不会被优先淘汰（批量 touch 生效）', () async {
      MediaCache.useQuotaForTest(accountSoft: 350, deviceHard: 100000);
      await MediaCache.store('room-1', 'event-a', _bytes(1, 100),
          accountId: 'alice');
      await MediaCache.store('room-1', 'event-b', _bytes(2, 100),
          accountId: 'alice');
      await MediaCache.store('room-1', 'event-c', _bytes(3, 100),
          accountId: 'alice');
      // 访问 A（命中 + touch）；B 成为最久未访问。
      expect(await MediaCache.cached('room-1', 'event-a', accountId: 'alice'),
          isNotNull);
      // 再写一个 → 超配额 → 应淘汰 B 而不是 A。
      await MediaCache.store('room-1', 'event-d', _bytes(4, 100),
          accountId: 'alice');

      expect(await MediaCache.cached('room-1', 'event-a', accountId: 'alice'),
          isNotNull,
          reason: '最近访问过的 A 必须保留');
      expect(await MediaCache.cached('room-1', 'event-b', accountId: 'alice'),
          isNull,
          reason: '最久未访问的 B 应被淘汰');
      expect(MediaCacheMetrics.evictedObjects, greaterThan(0));
      expect(MediaCacheMetrics.evictions, greaterThan(0));
    });

    test('命中路径只登记内存 pending，不产生逐次落库', () async {
      final payload = _bytes(9, 2048);
      await MediaCache.store('room-1', 'event-1', payload, accountId: 'alice');
      await MediaIndex.shared.flush();
      MediaCacheMetrics.reset();
      for (var i = 0; i < 5; i++) {
        expect(await MediaCache.cached('room-1', 'event-1',
            accountId: 'alice'), isNotNull);
      }
      expect(MediaCacheMetrics.touchFlushes, 0,
          reason: '5 次命中不得触发 5 次落库（批量 touch）');
      expect(MediaIndex.shared.pendingTouchCount, 1,
          reason: '同一对象在 debounce 窗口内只保留一条 pending');
      await MediaIndex.shared.flush();
      expect(MediaCacheMetrics.touchFlushes, 1);
    });
  });

  group('引用保护与 GC', () {
    test('删引用不删对象；最后一个引用消失后才可回收', () async {
      final payload = _bytes(5, 1024);
      final object = await MediaCache.store('chat-1', 'event-1', payload,
          accountId: 'alice');
      await MediaCache.store('moments', 'moment-1', payload, accountId: 'alice');
      expect(await _countFiles(documents, 'alice', 'objects'), 1);

      // 删除第一个引用：对象必须保留。
      await MediaCache.removeReference('chat-1', 'event-1', accountId: 'alice');
      expect(await object.exists(), isTrue, reason: '仍有其它引用，对象不得删除');
      final gc1 = await MediaCache.collectGarbage('alice',
          gracePeriod: Duration.zero);
      expect(gc1.collected, 0);
      expect(gc1.kept, 1);
      expect(await object.exists(), isTrue);

      // 删除第二个引用：对象变为可回收。
      await MediaCache.removeReference('moments', 'moment-1', accountId: 'alice');
      final gc2 = await MediaCache.collectGarbage('alice',
          gracePeriod: Duration.zero);
      expect(gc2.collected, 1);
      expect(gc2.collectedBytes, payload.length);
      expect(await object.exists(), isFalse);
      expect(MediaCacheMetrics.gcCollectedObjects, 1);
      expect(MediaCacheMetrics.gcRuns, 2);
    });

    test('引用计数由 refs 重算（不依赖计数器，崩溃不漂移）', () async {
      final payload = _bytes(6, 512);
      await MediaCache.store('chat-1', 'event-1', payload, accountId: 'alice');
      // 手工制造"引用文件丢失"（模拟崩溃/外部删除）：GC 应据此判定无引用。
      final ref = await _refFile(documents, 'alice', 'chat-1', 'event-1');
      await ref.delete();
      final report = await MediaCache.collectGarbage('alice',
          gracePeriod: Duration.zero);
      expect(report.collected, 1, reason: '引用文件不存在 → 无引用 → 可回收');
    });

    test('保护期内（对象刚写、ref 未写）不回收', () async {
      final payload = _bytes(8, 512);
      final object = await MediaCache.store('chat-1', 'event-1', payload,
          accountId: 'alice');
      final ref = await _refFile(documents, 'alice', 'chat-1', 'event-1');
      await ref.delete();
      final report = await MediaCache.collectGarbage('alice');
      expect(report.collected, 0);
      expect(report.skippedYoung, 1);
      expect(await object.exists(), isTrue);
    });

    test('并发读（pin）期间 GC 不得删除对象', () async {
      final payload = _bytes(12, 1024);
      final object = await MediaCache.store('chat-1', 'event-1', payload,
          accountId: 'alice');
      final ref = await _refFile(documents, 'alice', 'chat-1', 'event-1');
      await ref.delete(); // 让它成为"无引用"对象

      final pin = MediaCache.pinPath(object.path);
      expect(MediaCache.isPinned(object.path), isTrue,
          reason: 'pin 必须登记到缓存（path=${object.path}）');
      final during = await MediaCache.collectGarbage('alice',
          gracePeriod: Duration.zero);
      expect(during.collected, 0);
      expect(during.skippedPinned, 1);
      expect(await object.exists(), isTrue, reason: '播放/解码中的对象不得被删');

      pin.release();
      expect(MediaCache.isPinned(object.path), isFalse);
      final after = await MediaCache.collectGarbage('alice',
          gracePeriod: Duration.zero);
      expect(after.collected, 1);
      expect(await object.exists(), isFalse);
    });

    test('dryRun 只报告不删除', () async {
      final payload = _bytes(13, 256);
      final object = await MediaCache.store('chat-1', 'event-1', payload,
          accountId: 'alice');
      await (await _refFile(documents, 'alice', 'chat-1', 'event-1')).delete();
      final report = await MediaCache.collectGarbage('alice',
          gracePeriod: Duration.zero, dryRun: true);
      expect(report.collected, 1);
      expect(report.dryRun, isTrue);
      expect(await object.exists(), isTrue, reason: 'dryRun 不得删除任何对象');
    });
  });

  group('崩溃恢复与索引一致性', () {
    test('对象已写、索引缺失 → 首次访问完整校验后回填（lazy rebuild）', () async {
      final payload = _bytes(21, 4096);
      final hash = sha256.convert(payload).toString();
      final object = await _objectFile(documents, 'alice', hash);
      await object.writeAsBytes(payload, flush: true);
      await File('${object.path}.len').writeAsString('${payload.length}');
      await (await _refFile(documents, 'alice', 'room-1', 'event-1'))
          .writeAsString(hash);
      // 模拟"对象写完、索引未写就被杀"。
      await MediaIndex.shared.forgetObjects('alice', {hash});
      await MediaIndex.shared.flush();

      MediaCacheMetrics.reset();
      final first = await MediaCache.cached('room-1', 'event-1',
          accountId: 'alice');
      expect(first, isNotNull, reason: '索引缺失必须回退 legacy 读取');
      expect(MediaCacheMetrics.hashBytesRead, payload.length,
          reason: '缺失索引时做一次完整校验');
      MediaCacheMetrics.reset();
      // 该测试关心"回填后即走索引"，与对象大小无关，故临时把廉价路径门槛降为 0。
      MediaCache.useCheapPathMinBytesForTest(0);
      final second = await MediaCache.cached('room-1', 'event-1',
          accountId: 'alice');
      expect(second, isNotNull);
      expect(MediaCacheMetrics.hashBytesRead, 0, reason: '回填后即为廉价命中');
    });

    test('索引存在、对象缺失 → 失效索引并回退（不永久打不开）', () async {
      final payload = _bytes(22, 2048);
      final object = await MediaCache.store('room-1', 'event-1', payload,
          accountId: 'alice');
      await object.delete(); // 对象被外部删除
      final hit = await MediaCache.cached('room-1', 'event-1',
          accountId: 'alice');
      expect(hit, isNull, reason: '对象确实不存在 → 视为未命中（可重新下载）');
      expect(await object.exists(), isFalse);
      // 索引行已被失效：再次查询仍走 legacy，不会返回幽灵路径。
      expect(await MediaIndex.shared.lookup('alice', 'room-1', 'event-1'),
          isNull);
    });

    test('索引存在、对象被截断 → 廉价校验发现尺寸不符并失效', () async {
      final payload = _bytes(23, 4096);
      final object = await MediaCache.store('room-1', 'event-1', payload,
          accountId: 'alice');
      await object.writeAsBytes(payload.sublist(0, 10), flush: true);
      final hit = await MediaCache.cached('room-1', 'event-1',
          accountId: 'alice');
      expect(hit, isNull, reason: '尺寸不符 → 失效索引 + legacy 拒绝损坏对象');
      expect(await object.exists(), isFalse,
          reason: 'legacy 校验会清理损坏对象');
    });

    test('索引损坏（降级）时仍可读写媒体（失败降级）', () async {
      // 注入一个"打开必然失败"的工厂：验证索引不可用时的降级路径
      // （生产里可能因为初始化时序/路径不可写而出现）。
      final index = MediaIndex(
        databasePath: '${root.path}/support/broken.db',
        factory: _ThrowingFactory(),
      );
      index.resetForTest();
      MediaIndex.overrideShared(index);
      final payload = _bytes(24, 1024);
      final file = await MediaCache.store('room-1', 'event-1', payload,
          accountId: 'alice');
      expect(await file.exists(), isTrue, reason: '索引不可用不得阻止写对象');
      final hit = await MediaCache.cached('room-1', 'event-1',
          accountId: 'alice');
      expect(hit, isNotNull, reason: '索引不可用时回退 legacy 读取');
      expect(await hit!.readAsBytes(), payload);
      expect(MediaIndex.shared.degraded, isTrue);
    });
  });

  group('并发', () {
    test('并发写同一个 hash：1 个对象、无损坏', () async {
      final payload = _bytes(41, 16384);
      final results = await Future.wait([
        MediaCache.store('room-1', 'event-1', payload, accountId: 'alice'),
        MediaCache.store('room-1', 'event-2', payload, accountId: 'alice'),
        MediaCache.store('room-1', 'event-3', payload, accountId: 'alice'),
      ]);
      expect(await _countFiles(documents, 'alice', 'objects'), 1);
      expect(await _countFiles(documents, 'alice', 'refs'), 3);
      for (final file in results) {
        expect(await file.readAsBytes(), payload, reason: '并发写不得产生半写文件');
      }
    });

    test('并发读 + GC：pin 保护生效', () async {
      final payload = _bytes(42, 2048);
      final object = await MediaCache.store('room-1', 'event-1', payload,
          accountId: 'alice');
      await (await _refFile(documents, 'alice', 'room-1', 'event-1')).delete();
      final pin = MediaCache.pinPath(object.path);
      final futures = <Future<Object?>>[
        MediaCache.collectGarbage('alice', gracePeriod: Duration.zero),
        MediaCache.cached('room-1', 'event-1', accountId: 'alice'),
      ];
      final results = await Future.wait(futures);
      expect(await object.exists(), isTrue);
      expect(results[1], isNotNull, reason: '读取期间对象不得消失');
      pin.release();
    });
  });

  group('索引 schema、指标与脱敏', () {
    test('索引只存摘要：数据库文件中不含 roomId/eventId/accountId 明文', () async {
      const room = 'SECRET-ROOM-ID-9f3';
      const event = 'SECRET-EVENT-ID-4a1';
      const account = 'SECRET-ACCOUNT-7c2';
      await MediaCache.store(room, event, _bytes(51, 512), accountId: account);
      await MediaIndex.shared.flush();

      final entry = await MediaIndex.shared.lookup(account, room, event);
      expect(entry, isNotNull);
      expect(entry!.referenceKey,
          sha256.convert(utf8.encode(jsonEncode([room, event]))).toString());
      expect(entry.accountNamespace, sha256.convert(utf8.encode(account)).toString());
      expect(entry.objectName, isNot(contains(room)));

      final dbBytes = await File('${root.path}/support/index.db').readAsBytes();
      final text = String.fromCharCodes(dbBytes);
      expect(text.contains(room), isFalse, reason: '索引不得落明文 roomId');
      expect(text.contains(event), isFalse, reason: '索引不得落明文 eventId');
      expect(text.contains(account), isFalse, reason: '索引不得落明文账号');
    });

    test('指标快照字段齐备且可重置', () async {
      await MediaCache.store('room-1', 'event-1', _bytes(61, 1024),
          accountId: 'alice');
      await MediaCache.cached('room-1', 'event-1', accountId: 'alice');
      final snapshot = MediaCacheMetrics.snapshot();
      for (final key in const [
        'cache_lookups',
        'cache_lookup_ms',
        'index_lookups',
        'index_lookup_ms',
        'index_hits',
        'index_misses',
        'index_writes',
        'hash_bytes_read',
        'disk_bytes_read',
        'disk_bytes_written',
        'eviction_ms',
        'evictions',
        'gc_ms',
        'gc_runs',
        'gc_collected_objects',
        'gc_collected_bytes',
        'touch_flushes',
        'touched_objects',
        'pinned_paths',
      ]) {
        expect(snapshot.containsKey(key), isTrue, reason: '缺少指标：$key');
      }
      expect(snapshot['disk_bytes_written'], greaterThanOrEqualTo(1024));
      expect(snapshot['index_writes'], greaterThan(0));

      // 诊断行不含 PII：没有 room/event/账号/文件名明文。
      final line = MediaCacheMetrics.debugLine();
      expect(line, startsWith('[chatflow/mediacache]'));
      expect(line.contains('alice'), isFalse);
      expect(line.contains('room-1'), isFalse);
      expect(line.contains('event-1'), isFalse);

      MediaCacheMetrics.reset();
      expect(MediaCacheMetrics.hashBytesRead, 0);
      expect(MediaCacheMetrics.snapshot()['index_hits'], 0);
    });

    test('索引懒打开：构造时不创建数据库文件，首次查询才落盘', () async {
      final lazyPath = '${root.path}/support/lazy-index.db';
      final lazy = MediaIndex(
        databasePath: lazyPath,
        factory: databaseFactoryFfiNoIsolate,
      );
      expect(File(lazyPath).existsSync(), isFalse,
          reason: '构造 MediaIndex 不得产生任何磁盘动作（启动不做全量扫描）');
      await lazy.lookup('alice', 'room-1', 'event-1');
      expect(File(lazyPath).existsSync(), isTrue, reason: '首次查询才懒创建');
      await lazy.close();
    });

    test('索引按账号清理（clearAccount 同时清索引行）', () async {
      await MediaCache.store('room-1', 'event-1', _bytes(71, 512),
          accountId: 'alice');
      await MediaCache.store('room-1', 'event-1', _bytes(72, 512),
          accountId: 'bob');
      expect(await MediaIndex.shared.lookup('alice', 'room-1', 'event-1'),
          isNotNull);
      await MediaCache.clearAccount('alice');
      expect(await MediaIndex.shared.lookup('alice', 'room-1', 'event-1'),
          isNull);
      expect(await MediaIndex.shared.lookup('bob', 'room-1', 'event-1'),
          isNotNull, reason: '清理账号 A 不得影响账号 B 的索引');
    });
  });
}

/// 故意在打开数据库时抛错，用于验证"索引不可用 → 降级 legacy"。
final class _ThrowingFactory implements DatabaseFactory {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('index unavailable');

  @override
  Future<Database> openDatabase(String path,
          {OpenDatabaseOptions? options}) =>
      throw UnsupportedError('index unavailable');
}
