import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/device_gallery_source.dart';
import 'package:photo_manager/photo_manager.dart';

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

  test('首帧缓存：首次抽帧落盘，二次命中零抽帧', () async {
    final dir = _fixtureDirectory().createTempSync('vff-cache');
    addTearDown(() => dir.deleteSync(recursive: true));
    var fetches = 0;
    final asset = _FakeVideoAsset();

    Future<Uint8List?> fetch(String path, int positionMs) async {
      fetches++;
      return whitePng;
    }

    final first = await loadVideoFirstFrame(asset,
        fetch: fetch, cacheDir: () async => dir);
    expect(first, whitePng);
    expect(fetches, 1);
    // 缓存文件已写入 video_first_frame_cache。
    final cacheDir = Directory(
        '${dir.path}${Platform.pathSeparator}video_first_frame_cache');
    expect(cacheDir.listSync().length, 1, reason: '首帧必须落盘');

    // 二次（新 fetch 计数器，命中即不调用）：
    final second = await loadVideoFirstFrame(asset,
        fetch: (p, ms) async {
          fetches += 100;
          return whitePng;
        },
        cacheDir: () async => dir);
    expect(second, whitePng, reason: '命中缓存返回首次字节');
    expect(fetches, 1, reason: '缓存命中不得再抽帧');
  });

  test('抽帧失败返回 null 不落盘（占位保持）', () async {
    final dir = _fixtureDirectory().createTempSync('vff-miss');
    addTearDown(() => dir.deleteSync(recursive: true));
    final result = await loadVideoFirstFrame(
      _FakeVideoAsset(),
      fetch: (p, ms) async => null,
      cacheDir: () async => dir,
    );
    expect(result, isNull);
    final cacheDir = Directory(
        '${dir.path}${Platform.pathSeparator}video_first_frame_cache');
    expect(cacheDir.listSync(), isEmpty);
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
    '../../docs/verification/artifacts/2026-09-06/room-flow/gallery/video-fixtures')
  ..createSync(recursive: true);

final class _VideoAlbum extends AssetPathEntity {
  _VideoAlbum(this.asset) : super(id: 'video-album', name: 'Video');
  final AssetEntity asset;
  @override
  Future<List<AssetEntity>> getAssetListRange(
          {required int start, required int end, RequestType? type}) async =>
      start == 0 ? [asset] : [];
}
