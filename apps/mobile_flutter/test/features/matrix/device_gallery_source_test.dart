import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:liuhetong_mobile/features/matrix/device_gallery_source.dart';
import 'package:photo_manager/photo_manager.dart';

/// 相册数据源优化（P1）：
/// - 首屏只取 12 张（覆盖可见网格），后续页 20；
/// - 缩略图有界并发解码（峰值 ≤ galleryDecodeConcurrency，顺序保持）；
/// - 权限（仅授权缓存）与相册索引会话级复用。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('reopened gallery queries include photos created after first opening',
      () async {
    const channel = MethodChannel('com.fluttercandies/photo_manager');
    final options = <Map>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAssetPathList') {
        options.add(((call.arguments as Map)['option'] as Map)['child'] as Map);
        return {'data': <Map>[]};
      }
      return PermissionState.authorized.index;
    });
    addTearDown(() {
      GalleryAccessCache.invalidateAll();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    GalleryAccessCache.invalidateAll();
    await DeviceGallerySource.loadAlbums();
    await Future<void>.delayed(const Duration(milliseconds: 25));
    final screenshotTime = DateTime.now().millisecondsSinceEpoch;
    options.clear();
    GalleryAccessCache.invalidateAll();
    await DeviceGallerySource.loadAlbums();
    expect(options, hasLength(3));
    for (final option in options) {
      for (final key in ['createDate', 'updateDate']) {
        final bound = option[key] as Map;
        expect(
            bound['ignore'] == true || (bound['max'] as int) >= screenshotTime,
            isTrue,
            reason:
                '$key excludes images created while the app remains running');
      }
      expect((option['orders'] as List).first['asc'], false);
    }
  });
  test('visible image decoding is bounded and deduplicates concurrent requests',
      () async {
    final store = GalleryThumbnailStore();
    final assets =
        List.generate(8, (i) => _DeferredThumbnailAsset('bounded-$i'));
    final pending = [for (final asset in assets) store.load(asset)];
    final duplicate = store.load(assets.first);
    expect(assets.where((a) => a.calls > 0).length, galleryDecodeConcurrency);
    for (var i = 0; i < assets.length; i++) {
      assets[i].bytes.complete(Uint8List.fromList([i + 1]));
      await Future<void>.delayed(Duration.zero);
    }
    await Future.wait(pending);
    await duplicate;
    await store.load(assets.first);
    expect(assets.every((a) => a.calls == 1), isTrue);
  });

  test('lazy decoded image becomes a synchronous cached preview', () async {
    await GalleryAccessCache.shared.ensurePermission(() async => true);
    final page =
        await DeviceGalleryPager(album: _FakeAlbum([_StubAsset('preview')]))
            .loadNextPage();
    expect(page.single.thumbnail, isEmpty);
    await page.single.loadThumbnail!();
    expect(page.single.thumbnail, utf8.encode('preview'));
  });

  test('first authorization caches the actual permission scope', () async {
    const channel = MethodChannel('com.fluttercandies/photo_manager');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel, (call) async => PermissionState.authorized.index);
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    DeviceGallerySource.lastKnownPermissionScopeForTest = null;
    await DeviceGalleryPager(album: _FakeAlbum([])).ensureAccess();
    expect(GalleryAccessCache.shared.matchesPermissionScope('full'), isTrue);
    DeviceGallerySource.lastKnownPermissionScopeForTest = null;
  });

  test('invalidated album scans cannot repopulate the session index', () async {
    final cache = GalleryAccessCache.shared;
    final oldScan = Completer<List<GalleryAlbum>>();
    final pending = cache.loadAlbums(() => oldScan.future);
    cache.invalidateIndex();
    const fresh = GalleryAlbum(
        id: 'new', name: 'New', isRecent: false, isVideoOnly: false);
    await cache.loadAlbums(() async => [fresh]);
    oldScan.complete([]);
    await pending;
    expect(await cache.loadAlbums(() async => []), [fresh]);
  });

  test('page metadata returns before any image thumbnail decode', () async {
    await GalleryAccessCache.shared.ensurePermission(() async => true);
    final asset = _DeferredThumbnailAsset();
    final page = DeviceGalleryPager(album: _FakeAlbum([asset])).loadNextPage();
    var metadataReady = false;
    page.then((_) => metadataReady = true);
    await Future<void>.delayed(Duration.zero);
    expect(metadataReady, isTrue,
        reason: 'Metadata must not wait for a slow native thumbnail');
    expect(asset.calls, 0, reason: 'Decode only visible cells lazily');
    asset.bytes.complete(Uint8List.fromList([1]));
    await page;
  });
  setUp(() {
    GalleryAccessCache.shared.invalidate();
    DeviceGallerySource.lastKnownPermissionScopeForTest = null;
  });

  test(
      'mislabeled GIF bypasses static compression without copying original bytes',
      () async {
    final bytes =
        Uint8List.fromList([71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 0, 0, 0, 59]);
    final asset = _GifAsset(bytes);
    await GalleryAccessCache.shared.ensurePermission(() async => true);
    final photos =
        await DeviceGalleryPager(album: _FakeAlbum([asset])).loadNextPage();
    expect(identical(await photos.single.compressedBytes(), bytes), isTrue);
    expect(identical(await photos.single.originalBytes(), bytes), isTrue);
    expect(asset.staticCompressions, isEmpty);
  });

  test(
      'GIF file preflight rejects oversized bytes and canvas before origin bridge',
      () async {
    final dir = Directory(
        '../../docs/verification/artifacts/2026-09-06/room-flow/gallery');
    await dir.create(recursive: true);
    for (final dimensionsTooLarge in [false, true]) {
      final header = Uint8List.fromList([
        71,
        73,
        70,
        56,
        57,
        97,
        dimensionsTooLarge ? 255 : 1,
        dimensionsTooLarge ? 255 : 0,
        dimensionsTooLarge ? 255 : 1,
        dimensionsTooLarge ? 255 : 0
      ]);
      final file = File(
          '${dir.path}/preflight-${dimensionsTooLarge ? 'canvas' : 'bytes'}.gif');
      await file.writeAsBytes(header);
      if (!dimensionsTooLarge) {
        final handle = await file.open(mode: FileMode.append);
        await handle.truncate(20 * 1024 * 1024 + 1);
        await handle.close();
      }
      addTearDown(() => file.delete());
      final asset = _GifAsset(
          Uint8List.fromList([71, 73, 70, 56, 57, 97, 1, 0, 1, 0]),
          fixtureFile: file);
      await GalleryAccessCache.shared.ensurePermission(() async => true);
      final photos =
          await DeviceGalleryPager(album: _FakeAlbum([asset])).loadNextPage();
      await expectLater(photos.single.compressedBytes(), throwsFormatException);
      await expectLater(photos.single.originalBytes(), throwsFormatException);
      expect(asset.originReads, isEmpty);
    }
  });

  test('GIF file is read directly without a platform byte bridge', () async {
    final bytes =
        Uint8List.fromList([71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 0, 0, 0, 59]);
    final file = File(
        '../../docs/verification/artifacts/2026-09-06/room-flow/gallery/direct.gif');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    addTearDown(() => file.delete());
    final asset = _GifAsset(Uint8List(0), fixtureFile: file);
    await GalleryAccessCache.shared.ensurePermission(() async => true);
    final photos =
        await DeviceGalleryPager(album: _FakeAlbum([asset])).loadNextPage();
    expect(await photos.single.compressedBytes(), bytes);
    expect(asset.originReads, isEmpty);
  });

  group('decodeThumbnailsBounded（有界并发解码）', () {
    test('并发峰值不超过上限，且保持输入顺序', () async {
      var inFlight = 0;
      var peak = 0;
      final tasks = [
        for (var i = 0; i < 10; i++)
          () async {
            inFlight++;
            if (inFlight > peak) peak = inFlight;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            inFlight--;
            return Uint8List.fromList(utf8.encode('thumb-$i'));
          },
      ];
      final results = await decodeThumbnailsBounded(tasks);
      expect(results, hasLength(10));
      expect(
        results.map((bytes) => utf8.decode(bytes)).toList(),
        equals([for (var i = 0; i < 10; i++) 'thumb-$i']),
        reason: '解码结果必须保持输入顺序',
      );
      expect(peak, lessThanOrEqualTo(galleryDecodeConcurrency),
          reason: '并发解码峰值不得超过上限');
      expect(peak, greaterThan(1), reason: '确实存在并发（比顺序解码快）');
    });

    test('单张失败回退空占位，不中断整页', () async {
      final results = await decodeThumbnailsBounded([
        () async => Uint8List.fromList(const [1]),
        () async => throw StateError('decode failed'),
        () async => Uint8List.fromList(const [3]),
      ]);
      expect(results[0], const [1]);
      expect(results[1], isEmpty, reason: '失败条目回退空占位');
      expect(results[2], const [3]);
    });
  });

  group('DeviceGalleryPager（首屏 12 张）', () {
    test('首页默认 12 张，后续页 20 张', () async {
      final album = _FakeAlbum(List.generate(
        40,
        (i) => _StubAsset('asset-$i'),
      ));
      // 预置会话权限缓存，绕开 photo_manager 平台通道。
      await GalleryAccessCache.shared.ensurePermission(() async => true);
      final pager = DeviceGalleryPager(album: album);

      final first = await pager.loadNextPage();
      expect(first, hasLength(galleryFirstPageSize), reason: '首屏先返回可见网格的 12 张');
      expect(album.requestedCounts.first, galleryFirstPageSize);

      final second = await pager.loadNextPage();
      expect(second, hasLength(galleryPageSize), reason: '后续页保持 20 张');
      expect(album.requestedCounts.last, galleryPageSize);
      expect(pager.hasMore, isTrue);
    });

    test('显式传入 pageSize 时按传入值（调用方覆盖优先）', () async {
      final album =
          _FakeAlbum(List.generate(30, (i) => _StubAsset('asset-$i')));
      await GalleryAccessCache.shared.ensurePermission(() async => true);
      final pager = DeviceGalleryPager(album: album);
      final page = await pager.loadNextPage(pageSize: 5);
      expect(page, hasLength(5));
      expect(album.requestedCounts.single, 5);
    });

    test('不足一页时标记耗尽', () async {
      final album = _FakeAlbum([_StubAsset('only-one')]);
      await GalleryAccessCache.shared.ensurePermission(() async => true);
      final pager = DeviceGalleryPager(album: album);
      final page = await pager.loadNextPage();
      expect(page, hasLength(1));
      expect(pager.hasMore, isFalse);
      expect(await pager.loadNextPage(), isEmpty);
    });
  });

  group('GalleryAccessCache（权限/索引复用）', () {
    test('授权结果只请求一次并被复用；拒绝不缓存（设置页返回后重试）', () async {
      final cache = GalleryAccessCache.shared;
      var permissionRequests = 0;

      expect(
        await cache.ensurePermission(() async {
          permissionRequests++;
          return true;
        }),
        isTrue,
      );
      expect(
        await cache.ensurePermission(() async {
          permissionRequests++;
          return true;
        }),
        isTrue,
      );
      expect(permissionRequests, 1, reason: '已授权后权限请求必须复用缓存');

      cache.invalidate();
      expect(
        await cache.ensurePermission(() async {
          permissionRequests++;
          return false;
        }),
        isFalse,
      );
      expect(
        await cache.ensurePermission(() async {
          permissionRequests++;
          return false;
        }),
        isFalse,
      );
      expect(permissionRequests, 3, reason: '拒绝结果不得缓存，每次都重新请求');
    });

    test('相册索引加载一次后复用；invalidate 后重新加载', () async {
      final cache = GalleryAccessCache.shared;
      var loads = 0;
      final albums = [
        const GalleryAlbum(
            id: 'recent', name: '最近图片', isRecent: true, isVideoOnly: false),
      ];
      Future<List<GalleryAlbum>> load() async {
        loads++;
        return albums;
      }

      expect(await cache.loadAlbums(load), same(albums));
      expect(await cache.loadAlbums(load), same(albums));
      expect(loads, 1);

      cache.invalidate();
      expect(await cache.loadAlbums(load), same(albums));
      expect(loads, 2, reason: 'invalidate 后允许重新扫描');
    });
  });

  group('RequestType 透传（MIUI 本地视频修复）', () {
    test('isVideoOnly 相册 → RequestType.video；其余 → common', () {
      expect(requestTypeForAlbum(null), RequestType.common);
      expect(
        requestTypeForAlbum(const GalleryAlbum(
            id: 'videos', name: '本地视频', isRecent: false, isVideoOnly: true)),
        RequestType.video,
        reason: '本地视频相册 entity 为 null，必须靠 RequestType.video 定位',
      );
      expect(
        requestTypeForAlbum(const GalleryAlbum(
            id: 'recent', name: '最近图片', isRecent: true, isVideoOnly: false)),
        RequestType.common,
      );
    });

    test('pagerFor 按相册类型透传 RequestType（源码防回归）', () {
      final source = File('lib/features/matrix/device_gallery_source.dart')
          .readAsStringSync(encoding: utf8);
      final start = source.indexOf('static DeviceGalleryPager pagerFor');
      final end = source.indexOf(';', start);
      final body = source.substring(start, end);
      expect(body, contains('requestTypeForAlbum(album)'),
          reason: 'pagerFor 必须把 isVideoOnly 映射进 RequestType，'
              '否则"本地视频"退化为混合列表（MIUI 无视频）');
    });
  });

  group('recentAlbum 按 RequestType 分桶（缓存混用修复）', () {
    test('验证10：common → video → common 切换时缓存与实际查询各归各', () async {
      final cache = GalleryAccessCache.shared;
      cache.invalidate();
      await cache.ensurePermission(() async => true);

      final commonAlbum = _FakeAlbum([_StubAsset('c-1')]);
      final videoAlbum = _FakeAlbum([_StubAsset('v-1')]);
      var commonLoads = 0;
      var videoLoads = 0;

      // ① 最近图片（common）。
      final first = await cache.recentAlbum(RequestType.common, () async {
        commonLoads++;
        return commonAlbum;
      });
      expect(identical(first, commonAlbum), isTrue);
      expect(commonLoads, 1);

      // ② 切"本地视频"（video）：不得复用 common 桶。
      final second = await cache.recentAlbum(RequestType.video, () async {
        videoLoads++;
        return videoAlbum;
      });
      expect(identical(second, videoAlbum), isTrue,
          reason: '本地视频必须定位到 video 相册，而非复用 common 缓存');
      expect(videoLoads, 1, reason: 'video 桶首次加载');
      expect(commonLoads, 1, reason: 'video 查询不应触发 common 重扫');

      // ③ 切回"最近图片"：common 桶缓存命中，不重扫。
      final third = await cache.recentAlbum(RequestType.common, () async {
        commonLoads++;
        return commonAlbum;
      });
      expect(identical(third, commonAlbum), isTrue);
      expect(commonLoads, 1, reason: 'common 桶缓存命中');
      expect(videoLoads, 1);

      cache.invalidate();
    });

    test('分页器按自身类型定位相册（调用链：pagerFor → ensureAccess）', () async {
      final cache = GalleryAccessCache.shared;
      cache.invalidate();
      await cache.ensurePermission(() async => true);

      // 模拟系统媒体库：common 与 video 各自的"全部"相册。
      final commonAlbum = _FakeAlbum([_StubAsset('c-1')]);
      final videoAlbum = _FakeAlbum([_StubAsset('v-1')]);
      await cache.recentAlbum(RequestType.common, () async => commonAlbum);
      await cache.recentAlbum(RequestType.video, () async => videoAlbum);

      // common 定位一次后，video 分页器（entity=null）必须拿到 video 相册。
      final commonPager = DeviceGalleryPager(type: RequestType.common);
      await commonPager.ensureAccess();
      expect(identical(commonPager.resolvedAlbum, commonAlbum), isTrue);

      final videoPager = DeviceGalleryPager(type: RequestType.video);
      await videoPager.ensureAccess();
      expect(identical(videoPager.resolvedAlbum, videoAlbum), isTrue,
          reason: 'video 分页器不得复用 common 相册缓存（绕过视频查询）');
      expect(identical(videoPager.resolvedAlbum, commonAlbum), isFalse);

      cache.invalidate();
    });

    test('权限范围变化 → 缓存失效（部分授权不得当作完整访问）', () async {
      final cache = GalleryAccessCache.shared;
      cache.invalidate();
      await cache.ensurePermission(() async => true, scope: 'limited');
      expect(cache.matchesPermissionScope('limited'), isTrue);
      expect(cache.matchesPermissionScope('full'), isFalse,
          reason: '有限授权 ≠ 完整媒体库访问，范围指纹必须区分');

      // resume 探测到范围变为 full → invalidate。
      cache.invalidateIfScopeChanged('full');
      expect(cache.matchesPermissionScope('full'), isFalse,
          reason: '范围变化后缓存整体失效，需重新请求权限与索引');
      cache.invalidate();
    });
  });

  group('samplePositionsFor（按时长选取合法采样位置）', () {
    test('长视频保留全部候选点；短视频截到时长内', () {
      expect(samplePositionsFor(const Duration(minutes: 1)),
          [200, 500, 1000, 2000]);
      expect(samplePositionsFor(const Duration(milliseconds: 600)), [200, 500],
          reason: '600ms 视频：1000/2000ms 越界剔除');
    });

    test('极短视频回退到中点；未知时长按候选原样', () {
      expect(samplePositionsFor(const Duration(milliseconds: 120)), [60],
          reason: '短于全部候选点：取时长中点');
      expect(samplePositionsFor(null), [200, 500, 1000, 2000]);
      expect(samplePositionsFor(Duration.zero), [200, 500, 1000, 2000]);
    });
  });

  group('VideoFirstFrameStore（并发/重试/缓存策略）', () {
    test('验证13：抽帧实际并发受上限约束，排队任务按 FIFO 补位', () async {
      var inFlight = 0;
      var peak = 0;
      final started = <String>[];
      final store = VideoFirstFrameStore(
        maxConcurrent: 2,
        loader: (asset) async {
          started.add(asset.id);
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          inFlight--;
          return Uint8List.fromList(const [1, 2, 3]);
        },
      );
      final futures = [
        for (var i = 0; i < 8; i++) store.load(_StubAsset('asset-$i')),
      ];
      expect(store.activeExtractions, 2, reason: '同时最多 2 个底层解码任务');
      expect(store.queuedExtractions, 6, reason: '其余排队，不瞬时堆积');
      final frames = await Future.wait(futures);
      expect(frames.every((f) => f?.isNotEmpty == true), isTrue);
      expect(peak, lessThanOrEqualTo(2), reason: '并发峰值 ≤ 上限');
      expect(started.length, 8);
    });

    test('验证12：失败不占坑——退避后可重试，成功后缓存复用', () async {
      var now = DateTime(2026, 9, 5, 12, 0, 0);
      var calls = 0;
      final store = VideoFirstFrameStore(
        retryBackoff: const Duration(seconds: 2),
        clock: () => now,
        loader: (asset) async {
          calls++;
          if (calls <= 2) return null; // 前两次抽帧失败（返回 null）。
          return Uint8List.fromList(const [9]);
        },
      );
      final asset = _StubAsset('retry-asset');

      // 第一次失败。
      expect(await store.load(asset), isNull);
      expect(store.retriesExhaustedById(asset.id), isFalse);

      // 退避窗口内：快速失败，不提交解码任务。
      expect(await store.load(asset), isNull);
      expect(calls, 1, reason: '退避窗口内不得重复提交解码');

      // 退避窗口过后：自动有限重试（第 2 次仍失败 → 第 3 次成功）。
      now = now.add(const Duration(seconds: 3));
      expect(await store.load(asset), isNull);
      now = now.add(const Duration(seconds: 5));
      final frame = await store.load(asset);
      expect(frame, isNotNull, reason: '失败结果不永久占坑，可重试成功');
      expect(calls, 3);

      // 成功后内存缓存：后续调用零成本。
      now = now.add(const Duration(seconds: 5));
      await store.load(asset);
      expect(calls, 3, reason: '成功结果缓存复用，不再抽帧');
    });

    test('重试预算耗尽后快速失败；手动重试入口清零预算', () async {
      var now = DateTime(2026, 9, 5, 12, 0, 0);
      var calls = 0;
      final store = VideoFirstFrameStore(
        maxAttempts: 3,
        retryBackoff: const Duration(seconds: 1),
        clock: () => now,
        loader: (asset) async {
          calls++;
          return null;
        },
      );
      final asset = _StubAsset('hopeless-asset');
      // 三次尝试（每次跨过退避窗口）。
      for (var i = 0; i < 3; i++) {
        await store.load(asset);
        now = now.add(const Duration(seconds: 30));
      }
      expect(store.retriesExhaustedById(asset.id), isTrue,
          reason: '预算耗尽：UI 显示重试入口的依据');
      await store.load(asset);
      expect(calls, 3, reason: '预算耗尽后快速失败，不再提交原生任务');

      // 手动重试：清零预算 → 允许新一轮尝试。
      store.resetById(asset.id);
      expect(store.retriesExhaustedById(asset.id), isFalse);
      await store.load(asset);
      expect(calls, 4, reason: '手动重试入口恢复抽取能力（失效缓存能恢复）');
    });

    test('并发请求合并：同一资源并发调用共享一次抽帧', () async {
      var calls = 0;
      final store = VideoFirstFrameStore(
        loader: (asset) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return Uint8List.fromList(const [7]);
        },
      );
      final asset = _StubAsset('shared-asset');
      final results = await Future.wait(
          [store.load(asset), store.load(asset), store.load(asset)]);
      expect(results.every((r) => r != null), isTrue);
      expect(calls, 1, reason: '同一资源的并发请求合并为一个任务');
    });

    test('超时按失败记账（不会无限提交仍在运行的原生任务）', () async {
      var now = DateTime(2026, 9, 5, 12, 0, 0);
      var submissions = 0;
      final store = VideoFirstFrameStore(
        maxAttempts: 3,
        timeout: const Duration(milliseconds: 30),
        retryBackoff: const Duration(seconds: 1),
        clock: () => now,
        loader: (asset) async {
          submissions++;
          // 模拟原生任务悬挂不返回。
          await Completer<void>().future;
          return null;
        },
      );
      final asset = _StubAsset('stuck-asset');
      for (var i = 0; i < 3; i++) {
        unawaited(store.load(asset).catchError((_) => null));
        await Future<void>.delayed(const Duration(milliseconds: 60));
        now = now.add(const Duration(seconds: 30));
      }
      expect(submissions, 3, reason: '超时按失败记账，预算上限约束原生任务提交次数（3 次）');
      expect(store.retriesExhaustedById(asset.id), isTrue);
    });
  });

  group('loadVideoFirstFrame（多点位 + 缓存损坏失效）', () {
    // 2×2 白色 PNG（与 video_poster_extractor_test 同源，亮度≈255 过黑帧检测）。
    final whitePng = Uint8List.fromList(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAADklEQVR4nGP4DwYMEAoAU7oL9ZisIGcAAAAASUVORK5CYII='));

    Future<File> realVideoFile(String name) async {
      final dir = await _galleryFixtureDirectory('vff-src');
      final file = File('${dir.path}${Platform.pathSeparator}$name.mp4');
      await file.writeAsBytes(List.filled(64, 1), flush: true);
      return file;
    }

    test('按时长传合法采样位置给抽帧器（多点位避黑帧）', () async {
      final file = await realVideoFile('multi-pos');
      final asset = _StubVideoAsset(
        'multi-pos',
        path: file.path,
        durationOverride: const Duration(milliseconds: 600),
      );
      final positions = <int>[];
      final frame = await loadVideoFirstFrame(
        asset,
        fetch: (path, positionMs) async {
          positions.add(positionMs);
          return whitePng;
        },
        cacheDir: () async => _galleryFixtureDirectory('vff'),
      );
      expect(frame, isNotNull);
      expect(positions.first, 200, reason: '600ms 视频：从 200ms 开始多点位尝试');
    });

    test('缓存命中不再抽帧；空缓存文件删除后重新抽帧（损坏失效）', () async {
      final dir = await _galleryFixtureDirectory('vff-corrupt');
      final file = await realVideoFile('corrupt');
      final asset = _StubVideoAsset('corrupt', path: file.path);
      var extractions = 0;
      Future<Uint8List?> fetch(String path, int positionMs) async {
        extractions++;
        return whitePng;
      }

      // 首次：抽取并落盘。
      expect(
          await loadVideoFirstFrame(asset,
              fetch: fetch, cacheDir: () async => dir),
          isNotNull);
      expect(extractions, 1);
      // 第二次：磁盘缓存命中，不再抽帧。
      expect(
          await loadVideoFirstFrame(asset,
              fetch: fetch, cacheDir: () async => dir),
          isNotNull);
      expect(extractions, 1, reason: '成功封面磁盘缓存复用');

      // 把缓存文件写空（模拟写入中断/磁盘损坏）→ 不得把空字节当命中。
      final cacheDir = Directory(
          '${dir.path}${Platform.pathSeparator}video_first_frame_cache');
      for (final entry in cacheDir.listSync()) {
        if (entry is File) await entry.writeAsBytes(const [], flush: true);
      }
      expect(
          await loadVideoFirstFrame(asset,
              fetch: fetch, cacheDir: () async => dir),
          isNotNull);
      expect(extractions, 2, reason: '空缓存文件被删除并重新抽帧，不永远占坑');
    });
  });
}

final class _StubAsset extends AssetEntity {
  _StubAsset(String id)
      : super(
          id: id,
          typeInt: 1,
          width: 100,
          height: 100,
          mimeType: 'image/jpeg',
        );

  @override
  Future<Uint8List?> thumbnailDataWithSize(
    ThumbnailSize size, {
    ThumbnailFormat format = ThumbnailFormat.jpeg,
    int quality = 100,
    PMProgressHandler? progressHandler,
    PMCancelToken? cancelToken,
    int frame = 0,
  }) async =>
      Uint8List.fromList(utf8.encode(id));
}

final class _FakeAlbum extends AssetPathEntity {
  _FakeAlbum(this.assets) : super(id: 'fake-album', name: 'Fake');

  final List<AssetEntity> assets;
  final requestedCounts = <int>[];

  @override
  Future<List<AssetEntity>> getAssetListRange({
    required int start,
    required int end,
    RequestType? type,
  }) async {
    requestedCounts.add(end - start);
    final stop = end.clamp(0, assets.length);
    return assets.sublist(start.clamp(0, stop), stop);
  }
}

/// 视频资产替身：originFile 指向真实临时文件（缓存键需要 length），
/// videoDuration 可注入毫秒级时长。
final class _StubVideoAsset extends AssetEntity {
  _StubVideoAsset(
    String id, {
    required this.path,
    this.durationOverride,
  })  : _file = File(path),
        super(
            id: id, typeInt: 2, width: 100, height: 100, mimeType: 'video/mp4');

  final String path;
  final File _file;
  final Duration? durationOverride;

  @override
  Future<File?> get originFile async => _file;

  @override
  Duration get videoDuration => durationOverride ?? Duration.zero;
}

final class _GifAsset extends AssetEntity {
  _GifAsset(this.bytes, {this.fixtureFile})
      : super(
            id: 'mislabeled',
            typeInt: 1,
            width: 1,
            height: 1,
            mimeType: 'image/jpeg');
  final Uint8List bytes;
  final File? fixtureFile;
  final originReads = <bool>[];
  final staticCompressions = <int>[];
  @override
  Future<File?> get originFile async => fixtureFile;
  @override
  Future<Uint8List?> get originBytes async {
    originReads.add(true);
    return bytes;
  }

  @override
  Future<Uint8List?> thumbnailDataWithSize(ThumbnailSize size,
      {ThumbnailFormat format = ThumbnailFormat.jpeg,
      int quality = 100,
      int frame = 0,
      PMProgressHandler? progressHandler,
      PMCancelToken? cancelToken}) async {
    if (size.width > 200) staticCompressions.add(size.width);
    return Uint8List.fromList([1, 2, 3]);
  }
}

final class _DeferredThumbnailAsset extends AssetEntity {
  _DeferredThumbnailAsset([String id = 'slow'])
      : super(id: id, typeInt: 1, width: 100, height: 100);
  final bytes = Completer<Uint8List?>();
  final List<void> _calls = [];
  int get calls => _calls.length;
  @override
  Future<Uint8List?> thumbnailDataWithSize(ThumbnailSize size,
      {ThumbnailFormat format = ThumbnailFormat.jpeg,
      int quality = 100,
      PMProgressHandler? progressHandler,
      PMCancelToken? cancelToken,
      int frame = 0}) {
    _calls.add(null);
    return bytes.future;
  }
}

Future<Directory> _galleryFixtureDirectory(String prefix) async {
  final root = Directory(
      '../../docs/verification/artifacts/2026-09-06/room-flow/gallery');
  await root.create(recursive: true);
  final directory = await root.createTemp(prefix);
  addTearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  return directory;
}
