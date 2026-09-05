from pathlib import Path

p = Path('apps/mobile_flutter/lib/features/matrix/device_gallery_source.dart')
raw = p.read_text(encoding='utf-8')

# 1) loadNextPage：图片走有界解码；视频跳过系统缩略图（慢）→ 空占位+懒首帧
old = """    // 有界并发解码整页缩略图（保持顺序；失败→空占位，不丢条目）。
    final thumbnails = await decodeThumbnailsBounded([
      for (final asset in assets)
        () => asset.thumbnailDataWithSize(const ThumbnailSize.square(200)),
    ]);"""
new = """    // 规格#4：图片有界解码整页缩略图；**视频不等待系统缩略图**
    // （部分 ROM 上视频缩略图极慢，导致整页等待）——立即返回空占位，
    // 首帧由 firstFrame 闭包按 cell 懒加载（缓存命中秒回）。
    final thumbnails = await decodeThumbnailsBounded([
      for (final asset in assets)
        () => asset.type == AssetType.video
            ? Future<Uint8List?>.value(Uint8List(0))
            : asset.thumbnailDataWithSize(const ThumbnailSize.square(200)),
    ]);"""
assert old in raw, 'loadNextPage anchor missing'
raw = raw.replace(old, new, 1)

# 2) GalleryPhoto 构造处挂 firstFrame（memoized）
old = """          posterBytes: isVideo ? () async => _videoPosterBytes(asset) : null,"""
new = """          posterBytes: isVideo ? () async => _videoPosterBytes(asset) : null,
          firstFrame: isVideo ? _memoizedFirstFrame(asset) : null,"""
assert old in raw, 'poster anchor missing'
raw = raw.replace(old, new, 1)

# 3) 附加：memoize 帮手 + 视频首帧缓存（追加到 DeviceGalleryPager 类前）
anchor = "/// 兼容入口：一次性加载首页（供旧调用方过渡）；新代码请使用 [DeviceGalleryPager]。"
addition = '''/// 规格#4：视频首帧懒加载（磁盘缓存 video_first_frame_cache）。
///
/// key = sha256(path|id|durationMs|size)：对整文件做 sha256 比抽帧更贵，
/// 以 路径+时长+大小 组合作内容寻址代理（相册刷新时间戳变化即失效）。
/// [fetch] 注入抽帧实现（默认 video_compress 取 200ms 首帧），测试替身用。
Future<Uint8List?> loadVideoFirstFrame(
  AssetEntity asset, {
  Future<Uint8List?> Function(String path, int positionMs)? fetch,
  Future<Directory> Function()? cacheDir,
}) async {
  try {
    final origin = await asset.originFile;
    if (origin == null) return null;
    final dirFactory = cacheDir ?? getApplicationDocumentsDirectory;
    final dir = Directory(
        '${(await dirFactory()).path}${Platform.pathSeparator}video_first_frame_cache');
    await dir.create(recursive: true);
    final key = sha256
        .convert(utf8
            .encode('${origin.path}|${asset.id}|${asset.videoDuration}|${await origin.length()}'))
        .toString();
    final cacheFile = File('${dir.path}${Platform.pathSeparator}$key.jpg');
    if (await cacheFile.exists()) {
      return await cacheFile.readAsBytes();
    }
    final frame = await (fetch ??
            (path, positionMs) =>
                VideoCompress.getByteThumbnail(path, quality: 70, position: positionMs))(
        origin.path, 200);
    if (frame == null || frame.isEmpty) return null;
    await cacheFile.writeAsBytes(frame, flush: true);
    return frame;
  } catch (_) {
    return null; // 首帧失败不阻塞网格（保持占位）。
  }
}

Future<Uint8List?> Function() _memoizedFirstFrame(AssetEntity asset) {
  Future<Uint8List?>? pending;
  return () => pending ??= loadVideoFirstFrame(asset);
}

''' + anchor
raw = raw.replace(anchor, addition, 1)
p.write_text(raw, encoding='utf-8', newline='')
print('patched')
