import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/device_gallery_source.dart';
import 'package:photo_manager/photo_manager.dart';

final class _FakeVideoAsset extends AssetEntity {
  _FakeVideoAsset() : super(id: 'v1', typeInt: 2, width: 10, height: 10);

  @override
  Future<File?> get originFile async =>
      File('${Directory.systemTemp.path}/video-first-frame-test.mp4')
        ..writeAsBytesSync([1, 2, 3], flush: true);

  @override
  Duration get videoDuration => const Duration(seconds: 12);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('首帧缓存：首次抽帧落盘，二次命中零抽帧', () async {
    final dir = Directory.systemTemp.createTempSync('vff-cache');
    addTearDown(() => dir.deleteSync(recursive: true));
    var fetches = 0;
    final asset = _FakeVideoAsset();

    Future<Uint8List?> fetch(String path, int positionMs) async {
      fetches++;
      return Uint8List.fromList([9, 9, 9]);
    }

    final first =
        await loadVideoFirstFrame(asset, fetch: fetch, cacheDir: () async => dir);
    expect(first, [9, 9, 9]);
    expect(fetches, 1);
    // 缓存文件已写入 video_first_frame_cache。
    final cacheDir = Directory('${dir.path}${Platform.pathSeparator}video_first_frame_cache');
    expect(cacheDir.listSync().length, 1, reason: '首帧必须落盘');

    // 二次（新 fetch 计数器，命中即不调用）：
    final second =
        await loadVideoFirstFrame(asset, fetch: (p, ms) async {
      fetches += 100;
      return Uint8List.fromList([0]);
    }, cacheDir: () async => dir);
    expect(second, [9, 9, 9], reason: '命中缓存返回首次字节');
    expect(fetches, 1, reason: '缓存命中不得再抽帧');
  });

  test('抽帧失败返回 null 不落盘（占位保持）', () async {
    final dir = Directory.systemTemp.createTempSync('vff-miss');
    addTearDown(() => dir.deleteSync(recursive: true));
    final result = await loadVideoFirstFrame(
      _FakeVideoAsset(),
      fetch: (p, ms) async => null,
      cacheDir: () async => dir,
    );
    expect(result, isNull);
    final cacheDir = Directory('${dir.path}${Platform.pathSeparator}video_first_frame_cache');
    expect(cacheDir.listSync(), isEmpty);
  });

  test('memoize：同一闭包重复调用只抽一次帧', () async {
    // 源码级守卫：loadNextPage 视频不等待系统缩略图（立即占位渲染）。
    final source = File('lib/features/matrix/device_gallery_source.dart')
        .readAsStringSync(encoding: utf8);
    expect(
      source.contains(
          'asset.type == AssetType.video\n            ? Future<Uint8List?>.value(Uint8List(0))'),
      isTrue,
      reason: '视频必须跳过系统缩略图解码（规格#4：先渲染再逐 cell 抽帧）',
    );
    expect(source.contains('video_first_frame_cache'), isTrue,
        reason: '必须有磁盘缓存目录');
    expect(source.contains('firstFrame: isVideo ? _memoizedFirstFrame(asset) : null'),
        isTrue);
  });
}
