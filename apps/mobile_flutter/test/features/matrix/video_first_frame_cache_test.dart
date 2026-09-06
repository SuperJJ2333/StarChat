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

// 2×2 白色 PNG（亮度≈255，可通过多点位抽取的近黑帧检测）。
final Uint8List whitePng = Uint8List.fromList(base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAADklEQVR4nGP4DwYMEAoAU7oL9ZisIGcAAAAASUVORK5CYII='));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('首帧缓存：首次抽帧落盘，二次命中零抽帧', () async {
    final dir = Directory.systemTemp.createTempSync('vff-cache');
    addTearDown(() => dir.deleteSync(recursive: true));
    var fetches = 0;
    final asset = _FakeVideoAsset();

    Future<Uint8List?> fetch(String path, int positionMs) async {
      fetches++;
      return whitePng;
    }

    final first =
        await loadVideoFirstFrame(asset, fetch: fetch, cacheDir: () async => dir);
    expect(first, whitePng);
    expect(fetches, 1);
    // 缓存文件已写入 video_first_frame_cache。
    final cacheDir = Directory('${dir.path}${Platform.pathSeparator}video_first_frame_cache');
    expect(cacheDir.listSync().length, 1, reason: '首帧必须落盘');

    // 二次（新 fetch 计数器，命中即不调用）：
    final second =
        await loadVideoFirstFrame(asset, fetch: (p, ms) async {
      fetches += 100;
      return whitePng;
    }, cacheDir: () async => dir);
    expect(second, whitePng, reason: '命中缓存返回首次字节');
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

  test('memoize：同一视频条目重复请求只抽一次帧（成功缓存）', () async {
    // 源码级守卫：loadNextPage 视频不等待系统缩略图（立即占位渲染）。
    final source = File('lib/features/matrix/device_gallery_source.dart')
        .readAsStringSync(encoding: utf8);
    expect(
      source.contains('asset.type == AssetType.video'),
      isTrue,
      reason: '视频必须跳过系统缩略图解码（规格#4：先渲染再逐 cell 抽帧）',
    );
    expect(
      source.contains('Future<Uint8List?>.value(Uint8List(0))'),
      isTrue,
      reason: '视频跳过系统缩略图时立即返回空占位',
    );
    expect(source.contains('video_first_frame_cache'), isTrue,
        reason: '必须有磁盘缓存目录');
    // 成功结果的 memoize 职责移入全局协调器（失败不缓存、可重试）：
    // 网格闭包统一走 videoFirstFrameStore.load。
    expect(
      source.contains(
          'firstFrame: isVideo ? () => videoFirstFrameStore.load(asset) : null'),
      isTrue,
      reason: '首帧请求必须经全局协调器（成功缓存/失败退避/有界并发）',
    );
    // 行为级验证：同一资源重复 load 只抽一次（见 VideoFirstFrameStore 测试）。
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
