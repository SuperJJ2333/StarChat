import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/device_gallery_source.dart';
import 'package:photo_manager/photo_manager.dart';

/// 相册数据源优化（P1）：
/// - 首屏只取 12 张（覆盖可见网格），后续页 20；
/// - 缩略图有界并发解码（峰值 ≤ galleryDecodeConcurrency，顺序保持）；
/// - 权限（仅授权缓存）与相册索引会话级复用。
void main() {
  setUp(() {
    GalleryAccessCache.shared.invalidate();
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
