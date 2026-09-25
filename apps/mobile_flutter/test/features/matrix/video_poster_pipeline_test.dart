import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/video_poster_diagnostics.dart';
import 'package:liuhetong_mobile/features/matrix/video_poster_pipeline.dart';
import 'package:liuhetong_mobile/features/matrix/video_poster_session_cache.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

/// 不透明字节即可：本文件只验证流水线/缓存，不做图片解码。
Uint8List posterBytes = Uint8List.fromList(List<int>.filled(512, 0xAB));

Uint8List _bytes(int seed, int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i + seed) % 256));

/// 可观测的流水线夹具：所有来源都可注入，且只统计、不下载。
final class Harness {
  Harness({
    this.serverPoster,
    this.localVideo,
    Map<String, Uint8List>? disk,
    this.accountId = 'alice',
    VideoPosterExtractor? extract,
    VideoPosterDiagnostics? diagnostics,
    VideoPosterSessionCache? memory,
    Duration retryCooldown = Duration.zero,
    this.serverFailure,
  })  : disk = disk ?? <String, Uint8List>{},
        _extract = extract {
    final store = this.disk;
    pipeline = VideoPosterPipeline(
      accountId: accountId,
      roomId: 'room',
      memory: memory ?? VideoPosterSessionCache(),
      loadServerPoster: (mediaId) async {
        serverCalls++;
        final failure = serverFailure;
        if (failure != null) throw failure;
        return serverPoster;
      },
      readCachedPoster: (mediaId) async {
        diskReads++;
        return store['$accountId:$mediaId'];
      },
      writeCachedPoster: (mediaId, bytes) async {
        diskWrites++;
        store['$accountId:$mediaId'] = bytes;
      },
      findLocalVideoFile: (mediaId) async {
        localProbes++;
        return localVideo;
      },
      extract: (file, onFrameDecoded) async {
        extractions++;
        extractedFiles.add(file.path);
        final impl = _extract;
        if (impl == null) throw StateError('no extractor configured');
        return impl(file, onFrameDecoded);
      },
      diagnostics: diagnostics,
      retryCooldown: retryCooldown,
    );
  }

  final Uint8List? serverPoster;
  final File? localVideo;
  final Map<String, Uint8List> disk;
  final String accountId;
  final Object? serverFailure;
  final VideoPosterExtractor? _extract;
  late final VideoPosterPipeline pipeline;

  int serverCalls = 0;
  int diskReads = 0;
  int diskWrites = 0;
  int localProbes = 0;
  int extractions = 0;
  final List<String> extractedFiles = [];

  /// **下载字节数**：封面路径没有下载入口，恒为 0（断言用）。
  int get downloadBytes => pipeline.downloadBytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory scratch;
  setUp(() async {
    clearMediaMemoryCaches();
    final root = await Directory('../../docs/verification/artifacts/2026-09-17')
        .create(recursive: true);
    scratch = await root.createTemp('video-poster-test-');
    PathProviderPlatform.instance = _Paths(scratch.path);
    addTearDown(() async {
      clearMediaMemoryCaches();
      if (await scratch.exists()) await scratch.delete(recursive: true);
    });
  });

  File localVideoFile(String name, {int bytes = 4096}) {
    final file = File('${scratch.path}/$name');
    file.writeAsBytesSync(_bytes(7, bytes));
    return file;
  }

  group('Test 1：有 poster → 直接显示，不碰本地文件', () {
    test('服务端 poster 命中即返回，第二次走内存缓存', () async {
      final h = Harness(serverPoster: posterBytes);
      final first = await h.pipeline.resolve('m1');
      expect(first.hasPoster, isTrue);
      expect(first.source, VideoPosterSource.server);
      expect(first.cacheHit, isFalse);
      expect(first.downloadBytes, 0);
      expect(h.diskReads, 0, reason: '服务端已有 poster 时不必读本地缓存');
      expect(h.localProbes, 0, reason: '有 poster 时必须不探测/不抽帧本地视频');
      expect(h.extractions, 0);

      final second = await h.pipeline.resolve('m1');
      expect(second.source, VideoPosterSource.memory);
      expect(second.cacheHit, isTrue);
      expect(h.serverCalls, 1, reason: '第二次命中内存，不再请求服务端');
      expect(h.pipeline.memoryHits, 1);
    });

    test('并发解析同一媒体只生成一次（单飞）', () async {
      final gate = Completer<void>();
      final h = Harness(
        localVideo: localVideoFile('single.mp4'),
        extract: (file, _) async {
          await gate.future;
          return posterBytes;
        },
      );
      final first = h.pipeline.resolve('m1');
      final second = h.pipeline.resolve('m1');
      gate.complete();
      final results = await Future.wait([first, second]);
      expect(results.every((outcome) => outcome.hasPoster), isTrue);
      expect(h.extractions, 1, reason: '同一媒体并发解析只生成一次');
    });
  });

  group('Test 2：无 poster → 占位 → 后台生成 → 更新缓存', () {
    test('本地已有视频文件时抽帧生成并写回缓存', () async {
      final h = Harness(
        localVideo: localVideoFile('gen.mp4'),
        extract: (file, onFrameDecoded) async {
          onFrameDecoded?.call(3000);
          return posterBytes;
        },
      );
      final outcome = await h.pipeline.resolve('m2');

      expect(outcome.hasPoster, isTrue);
      expect(outcome.source, VideoPosterSource.localFrame);
      expect(outcome.downloadBytes, 0, reason: '抽帧不得产生任何下载');
      expect(h.diskWrites, 1, reason: '生成后必须更新缓存');
      expect(h.disk['alice:m2'], same(posterBytes));
      expect(outcome.decodeMs, greaterThanOrEqualTo(3));
      expect(h.pipeline.localFrameGenerations, 1);
    });

    test('视频已在本地但抽帧失败 → 占位（可重试），不下载视频', () async {
      final h = Harness(
        localVideo: localVideoFile('black.mp4'),
        extract: (file, _) async => null,
      );
      final outcome = await h.pipeline.resolve('m2b');

      expect(outcome.hasPoster, isFalse);
      expect(outcome.source, VideoPosterSource.placeholder);
      expect(outcome.downloadBytes, 0);
      expect(h.diskWrites, 0);
      expect(h.pipeline.extractionFailures, 1);
    });

    test('抽帧失败后有冷却；播放后可 forceGenerate 补生成', () async {
      final h = Harness(
        localVideo: localVideoFile('cooldown.mp4'),
        retryCooldown: const Duration(minutes: 5),
        extract: (file, _) async => null,
      );
      await h.pipeline.resolve('m3');
      await h.pipeline.resolve('m3');
      expect(h.extractions, 1, reason: '冷却期内不重复调用原生抽帧');
      expect(h.localProbes, 1);

      await h.pipeline.resolve('m3', forceGenerate: true);
      expect(h.extractions, 2, reason: 'forceGenerate 用于播放后补生成');
      expect(h.localProbes, 2);

      // 撤回/删除后的 forget：冷却与来源归属一并丢弃。
      h.pipeline.forget('m3');
      await h.pipeline.resolve('m3');
      expect(h.extractions, 3, reason: 'forget 后不再受冷却限制');
      expect(h.localProbes, 3);
    });
  });

  group('Test 3：大视频绝不为了封面下载', () {
    test('500MB 远端视频无 poster 且本地无文件 → 占位，0 下载 / 0 抽帧', () async {
      final big = File('${scratch.path}/huge-remote.mp4');
      // 稀疏文件：500MB 逻辑大小，不实际占用磁盘。
      final handle = await big.open(mode: FileMode.write);
      await handle.truncate(500 * 1024 * 1024);
      await handle.close();
      expect(await big.length(), 500 * 1024 * 1024);

      // 远端视频、无 poster、本地没有该视频（夹具只暴露「本地已存在的文件」）。
      final h = Harness(localVideo: null);
      final outcome = await h.pipeline.resolve('big');

      expect(outcome.hasPoster, isFalse);
      expect(outcome.source, VideoPosterSource.placeholder);
      expect(outcome.downloadBytes, 0);
      expect(h.extractions, 0);
      expect(h.localProbes, 1, reason: '只做一次本地存在性探测');
    });

    test('500MB 本地视频 + 服务端有 poster → 用 poster，不解码大文件', () async {
      final big = localVideoFile('huge-local.mp4', bytes: 512);
      final handle = await big.open(mode: FileMode.append);
      await handle.truncate(500 * 1024 * 1024); // 稀疏放大到 500MB
      await handle.close();

      final h = Harness(serverPoster: posterBytes, localVideo: big);
      final outcome = await h.pipeline.resolve('big2');

      expect(outcome.source, VideoPosterSource.server);
      expect(h.extractions, 0, reason: '有服务端 poster 时绝不解码 500MB 大文件');
      expect(h.localProbes, 0);
    });

    test('结构性防回归：流水线源码没有任何视频下载入口', () {
      final source = File('lib/features/matrix/video_poster_pipeline.dart')
          .readAsStringSync();
      for (final forbidden in const [
        'resolveCachedVideoFile',
        'loadAttachment',
        'downloadMediaContent',
        'downloadAndDecryptAttachment',
        '_downloadMedia',
      ]) {
        expect(source.contains(forbidden), isFalse,
            reason: '封面路径不允许出现视频下载入口：$forbidden');
      }
      expect(source.contains('VideoPosterSource.placeholder'), isTrue,
          reason: '无封面时必须走占位');
    });
  });

  group('Test 5：缓存命中', () {
    test('第一次抽帧生成，第二次（新流水线、空内存）直读磁盘', () async {
      final disk = <String, Uint8List>{};
      final first = Harness(
        disk: disk,
        localVideo: localVideoFile('hit.mp4'),
        extract: (file, _) async => posterBytes,
      );
      final a = await first.pipeline.resolve('m5');
      expect(a.source, VideoPosterSource.localFrame);
      expect(first.extractions, 1);
      expect(first.diskWrites, 1);

      // 模拟重新进入会话：内存 LRU 全新，持久缓存保留。
      final second = Harness(disk: disk, localVideo: localVideoFile('hit.mp4'));
      final b = await second.pipeline.resolve('m5');
      expect(b.hasPoster, isTrue);
      expect(b.source, VideoPosterSource.disk);
      expect(b.cacheHit, isTrue);
      expect(second.extractions, 0, reason: '第二次必须直接读缓存');
      expect(second.localProbes, 0, reason: '缓存命中时不必探测本地文件');
      expect(second.diskReads, 1);
    });
  });

  group('Test 6：账号隔离', () {
    test('MediaCache 账号命名空间隔离封面（A 写 B 不可读）', () async {
      final ref = videoPosterCacheRefId('event-1');
      await MediaCache.store('room-1', ref, posterBytes, accountId: 'alice');

      final a =
          await MediaCache.probeCachedObject('room-1', ref, accountId: 'alice');
      final b =
          await MediaCache.probeCachedObject('room-1', ref, accountId: 'bob');
      expect(a, isNotNull, reason: '账号 A 自己的封面可读');
      expect(b, isNull, reason: '账号 B 绝不能读到账号 A 的封面缓存');

      // 内容寻址：同账号内同字节只占一个物理对象（跨房间去重）。
      await MediaCache.store(
          'room-2', videoPosterCacheRefId('event-2'), posterBytes,
          accountId: 'alice');
      final a2 = await MediaCache.probeCachedObject(
          'room-2', videoPosterCacheRefId('event-2'),
          accountId: 'alice');
      expect(a2!.path, a!.path, reason: '同字节封面共用一个对象文件');
    });

    test('流水线缓存键含账号：B 账号不会命中 A 的持久缓存', () async {
      final disk = <String, Uint8List>{};
      final alice = Harness(
        accountId: 'alice',
        disk: disk,
        localVideo: localVideoFile('acct.mp4'),
        extract: (file, _) async => posterBytes,
      );
      await alice.pipeline.resolve('same-event');

      final bob = Harness(accountId: 'bob', disk: disk);
      final outcome = await bob.pipeline.resolve('same-event');
      expect(outcome.source, VideoPosterSource.placeholder,
          reason: '账号 B 不得命中账号 A 的封面缓存');
      expect(bob.diskReads, 1);
    });
  });

  group('诊断与健壮性', () {
    const secretId = 'secret-event-id-1';

    test('诊断日志只含白名单字段，且 ID 不可反查', () async {
      final lines = <String>[];
      final diagnostics =
          VideoPosterDiagnostics(log: lines.add, salt: 'account-salt');
      final h = Harness(serverPoster: posterBytes, diagnostics: diagnostics);

      await h.pipeline.resolve(secretId);

      expect(lines, hasLength(1));
      final line = lines.single;
      expect(line, contains('[chatflow/media]'));
      expect(line, contains('source=server'));
      expect(line, contains('cache_hit=false'));
      expect(line, contains('download_bytes=0'));
      expect(line, contains('generate_ms='));
      expect(line, contains('decode_ms='));
      expect(line.contains(secretId), isFalse, reason: '禁止记录媒体原始 ID');
      expect(line.contains('account-salt'), isFalse, reason: '盐本身也不得出现在日志里');
      expect(diagnostics.lastRecord!['id'], diagnostics.fingerprint(secretId));
      expect(diagnostics.lastRecord!.keys.toList(),
          VideoPosterDiagnostics.fieldOrder);
    });

    test('poster fingerprints expire with diagnostics instance', () {
      final first = VideoPosterDiagnostics(salt: 'account-salt');
      final second = VideoPosterDiagnostics(salt: 'account-salt');
      expect(first.fingerprint(secretId), first.fingerprint(secretId));
      expect(second.fingerprint(secretId), isNot(first.fingerprint(secretId)));
    });

    test('poster diagnostics stay off without an explicit diagnostic sink', () {
      final diagnostics = VideoPosterDiagnostics();
      diagnostics.record(
        videoId: secretId,
        source: 'server',
        cacheHit: false,
        generateMs: 1,
        decodeMs: 2,
        downloadBytes: 3,
      );
      const diagnosticBuild =
          bool.fromEnvironment('CHATFLOW_PERFORMANCE_METRICS');
      expect(diagnostics.enabled, diagnosticBuild);
      expect(diagnostics.lastRecord, diagnosticBuild ? isNotNull : isNull);
    });

    test('unrecognized poster source cannot enter diagnostic log', () {
      final lines = <String>[];
      final diagnostics = VideoPosterDiagnostics(log: lines.add);
      diagnostics.record(
        videoId: secretId,
        source: 'private-user-id',
        cacheHit: false,
        generateMs: 1,
        decodeMs: 2,
        downloadBytes: 3,
      );
      expect(lines.single, isNot(contains('private-user-id')));
      expect(diagnostics.lastRecord!['source'], 'unknown');
    });

    test('日志回调抛异常不影响封面加载（诊断失败安全）', () async {
      final diagnostics = VideoPosterDiagnostics(
          log: (_) => throw StateError('logger exploded'));
      final h = Harness(serverPoster: posterBytes, diagnostics: diagnostics);
      final outcome = await h.pipeline.resolve('m-safe');
      expect(outcome.hasPoster, isTrue);
      expect(outcome.source, VideoPosterSource.server);
    });

    test('服务端取图抛错时不崩溃，降级到本地来源', () async {
      final h = Harness(
        serverFailure: StateError('timeline window unavailable'),
        localVideo: localVideoFile('fallback.mp4'),
        extract: (file, _) async => posterBytes,
      );
      final outcome = await h.pipeline.resolve('m-fallback');
      expect(outcome.hasPoster, isTrue);
      expect(outcome.source, VideoPosterSource.localFrame);
      expect(h.serverCalls, 1);
    });

    test('封面写盘失败不阻断本次显示', () async {
      final failing = VideoPosterPipeline(
        accountId: 'alice',
        roomId: 'room',
        memory: VideoPosterSessionCache(),
        loadServerPoster: (_) async => null,
        readCachedPoster: (_) async => null,
        writeCachedPoster: (_, __) async => throw const FileSystemException(),
        findLocalVideoFile: (_) async => localVideoFile('wfail.mp4'),
        extract: (file, _) async => posterBytes,
        retryCooldown: Duration.zero,
      );
      final outcome = await failing.resolve('m-write-fail');
      expect(outcome.hasPoster, isTrue);
      expect(outcome.source, VideoPosterSource.localFrame);
      expect(outcome.downloadBytes, 0);
    });

    test('空媒体 ID 直接占位（不触碰任何来源）', () async {
      final h = Harness(serverPoster: posterBytes);
      final outcome = await h.pipeline.resolve('');
      expect(outcome.source, VideoPosterSource.placeholder);
      expect(h.serverCalls, 0);
      expect(h.localProbes, 0);
    });

    test('流水线缓存键形状：账号|房间|媒体|版本|规格', () {
      final h = Harness(accountId: 'alice');
      expect(h.pipeline.keyFor('m1'), 'alice|room|m1|m1|$chatVideoPosterSpec');
    });
  });

  group('MediaCache 廉价探测（避开大文件重哈希）', () {
    test('probeCachedObject 命中已落盘对象且不做哈希校验', () async {
      final payload = _bytes(3, 2048);
      final stored =
          await MediaCache.store('room', 'event', payload, accountId: 'alice');
      final probed = await MediaCache.probeCachedObject('room', 'event',
          accountId: 'alice');
      expect(probed, isNotNull);
      expect(probed!.path, stored.path, reason: '同一物理对象');
      expect(await probed.length(), payload.length);
      expect(
          await MediaCache.probeCachedObject('room', 'absent',
              accountId: 'alice'),
          isNull);
    });

    test('探测不替代完整性校验：cached() 仍拒绝被篡改的对象', () async {
      final payload = _bytes(5, 1024);
      final stored = await MediaCache.store('room', 'tampered', payload,
          accountId: 'alice');
      await stored.writeAsBytes(_bytes(9, payload.length));
      expect(
          await MediaCache.probeCachedObject('room', 'tampered',
              accountId: 'alice'),
          isNotNull,
          reason: '探测只看存在性（供抽帧封面使用）');
      expect(
          await MediaCache.cached('room', 'tampered',
              accountId: 'alice',
              contentSha256: sha256.convert(payload).toString()),
          isNull,
          reason: 'cached() 必须继续做完整性校验');
    });
  });
}
