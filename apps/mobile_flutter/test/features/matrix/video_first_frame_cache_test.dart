import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/device_gallery_source.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:photo_manager/photo_manager.dart';

/// Phase 2：首帧缓存并入统一对象库（`MediaCache`），不再有独立的
/// `video_first_frame_cache/` 目录。测试通过 PathProvider 注入隔离目录。
class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

final class _FakeVideoAsset extends AssetEntity {
  _FakeVideoAsset() : super(id: 'v1', typeInt: 2, width: 10, height: 10);

  final reads = <String>[];

  @override
  Future<File?> get originFile async {
    reads.add('original');
    return File('${_fixtureDirectory().path}/video-first-frame-test.mp4')
      ..writeAsBytesSync([1, 2, 3], flush: true);
  }

  @override
  Future<Uint8List?> thumbnailDataWithSize(ThumbnailSize size,
      {ThumbnailFormat format = ThumbnailFormat.jpeg,
      int quality = 100,
      PMProgressHandler? progressHandler,
      PMCancelToken? cancelToken,
      int frame = 0}) async {
    reads.add('system-thumbnail');
    return whitePng;
  }

  @override
  Duration get videoDuration => const Duration(seconds: 12);
}

// 2×2 白色 PNG（亮度≈255，可通过多点位抽取的近黑帧检测）。
final Uint8List whitePng = Uint8List.fromList(base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAADklEQVR4nGP4DwYMEAoAU7oL9ZisIGcAAAAASUVORK5CYII='));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory scratch;
  setUp(() {
    clearMediaMemoryCaches();
    scratch = _fixtureDirectory().createTempSync('vff-cache');
    PathProviderPlatform.instance = _Paths(scratch.path);
    addTearDown(() {
      clearMediaMemoryCaches();
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    });
  });

  test('首帧缓存：首次抽帧落盘到统一对象库，二次命中零抽帧', () async {
    var fetches = 0;
    final asset = _FakeVideoAsset();

    Future<Uint8List?> fetch(String path, int positionMs) async {
      fetches++;
      return whitePng;
    }

    final first = await loadVideoFirstFrame(asset, fetch: fetch);
    expect(first, whitePng);
    expect(fetches, 1);

    // 落盘位置：统一对象库（objects/<sha256> + refs/<logical-ref>）。
    final eventId = await videoFirstFrameCacheEventId(asset);
    expect(eventId, startsWith(videoFirstFrameVariant));
    final cached = await MediaCache.probeCachedObject(
        videoFirstFrameRoomId, eventId);
    expect(cached, isNotNull, reason: '首帧必须落盘到统一对象库');
    expect(await cached!.readAsBytes(), whitePng);
    expect(cached.path.replaceAll(r'\', '/'), contains('/objects/'));
    expect(
        Directory('${scratch.path}${Platform.pathSeparator}video_first_frame_cache')
            .existsSync(),
        isFalse,
        reason: '不再维护独立的无配额首帧目录');

    // 二次（新 fetch 计数器，命中即不调用）：
    final second = await loadVideoFirstFrame(asset,
        fetch: (p, ms) async {
          fetches += 100;
          return whitePng;
        });
    expect(second, whitePng, reason: '命中缓存返回首次字节');
    expect(fetches, 1, reason: '缓存命中不得再抽帧');
  });

  test('抽帧失败返回 null 不落盘（占位保持）', () async {
    final asset = _FakeVideoAsset();
    final result = await loadVideoFirstFrame(
      asset,
      fetch: (p, ms) async => null,
    );
    expect(result, isNull);
    final eventId = await videoFirstFrameCacheEventId(asset);
    expect(
        await MediaCache.probeCachedObject(videoFirstFrameRoomId, eventId),
        isNull,
        reason: '失败不得留下缓存对象');
  });

  test('空缓存对象视为损坏：删除后重新抽帧，不永远占坑', () async {
    var extractions = 0;
    final asset = _FakeVideoAsset();
    Future<Uint8List?> fetch(String path, int positionMs) async {
      extractions++;
      return whitePng;
    }

    expect(await loadVideoFirstFrame(asset, fetch: fetch), isNotNull);
    expect(extractions, 1);

    // 模拟写入中断：把对象写成空文件。
    final eventId = await videoFirstFrameCacheEventId(asset);
    final cached = await MediaCache.probeCachedObject(
        videoFirstFrameRoomId, eventId);
    await cached!.writeAsBytes(const [], flush: true);

    expect(await loadVideoFirstFrame(asset, fetch: fetch), isNotNull);
    expect(extractions, 2, reason: '空缓存对象被重新抽帧覆盖，不永远占坑');
  });

  test(
      'video metadata immediately exposes placeholder and lazy first-frame access',
      () async {
    GalleryAccessCache.invalidateAll();
    DeviceGallerySource.lastKnownPermissionScopeForTest = null;
    await GalleryAccessCache.shared.ensurePermission(() async => true);
    addTearDown(GalleryAccessCache.invalidateAll);
    final asset = _FakeVideoAsset();
    final page =
        await DeviceGalleryPager(album: _VideoAlbum(asset)).loadNextPage();
    expect(page, hasLength(1));
    expect(page.single.isVideo, isTrue);
    expect(page.single.thumbnail, isEmpty,
        reason: 'Video metadata renders a placeholder immediately');
    expect(page.single.loadThumbnail, isNull,
        reason: 'Video must bypass the image system-thumbnail decoder');
    expect(page.single.firstFrame, isNotNull,
        reason: 'Visible video cells retain their lazy first-frame loader');
    expect(page.single.duration, const Duration(seconds: 12));
    expect(asset.reads, isEmpty,
        reason:
            'Fetching page metadata must perform neither original-file IO nor native thumbnail decoding');
  });

  test('memoize：同一视频条目重复请求只抽一次帧（成功缓存）', () async {
    var extractions = 0;
    final store = VideoFirstFrameStore(
      loader: (asset) async {
        extractions++;
        return whitePng;
      },
    );
    final asset = _FakeVideoAsset();
    expect(await store.load(asset), whitePng);
    expect(await store.load(asset), whitePng);
    expect(await store.load(asset), whitePng);
    expect(extractions, 1, reason: '成功结果 memoize：重复调用零抽帧');
  });
}

Directory _fixtureDirectory() => Directory(
    '../../docs/verification/artifacts/2026-09-17/gallery/video-fixtures')
  ..createSync(recursive: true);

final class _VideoAlbum extends AssetPathEntity {
  _VideoAlbum(this.asset) : super(id: 'video-album', name: 'Video');
  final AssetEntity asset;
  @override
  Future<List<AssetEntity>> getAssetListRange(
          {required int start, required int end, RequestType? type}) async =>
      start == 0 ? [asset] : [];
}
