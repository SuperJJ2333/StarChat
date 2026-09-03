import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

import 'video_transcode.dart';

export 'video_transcode.dart'
    show
        VideoRendition,
        formatBytes,
        maxOriginalVideoBytes,
        shouldRetryVideoAtLowerQuality,
        videoCompressionTargetRatio,
        videoCompressionRetryThresholdBytes,
        transcodeForChat;

final class GalleryPhoto {
  const GalleryPhoto({
    required this.id,
    required this.thumbnail,
    required this.compressedBytes,
    required this.originalBytes,
    this.mimeType = 'image/jpeg',
    this.isVideo = false,
    this.duration,
    this.originalSizeBytes,
    this.compressedPreviewFile,
    this.posterBytes,
  });

  final String id;
  final Uint8List thumbnail;
  final Future<Uint8List> Function() compressedBytes;
  final Future<Uint8List> Function() originalBytes;
  final String mimeType;

  /// 视频条目：网格带时长角标；发送默认压缩，
  /// 勾选“原图”时受 [maxOriginalVideoBytes] 上限拦截。
  final bool isVideo;
  final Duration? duration;

  /// 原始文件大小（惰性读取），用于“原图”模式下 20MB 视频拦截。
  final Future<int> Function()? originalSizeBytes;

  /// 视频预览/发送共用的压缩产物及回退信息（预览页播放与发送复用同一份）。
  /// 仅视频条目提供。
  final Future<VideoRendition> Function()? compressedPreviewFile;

  /// 视频封面帧（约 480px，保持画面比例）：聊天消息发送时随事件附带，
  /// 接收端无需下载整个视频即可渲染海报。
  final Future<Uint8List?> Function()? posterBytes;
}

/// 相册数据源异常分类：用于向用户呈现可操作的引导。
sealed class GallerySourceError implements Exception {
  final String message;
  GallerySourceError(this.message);
}

final class GalleryPermissionDenied extends GallerySourceError {
  GalleryPermissionDenied()
      : super('未获得相册权限。点击下方「前往设置」，'
            '允许畅聊访问照片后返回本页即可自动加载。');
}

final class GalleryUnavailable extends GallerySourceError {
  GalleryUnavailable([String detail = '']) : super('相册暂不可用 $detail'.trim());
}

/// 相册分页大小：首屏与每次追加各加载一页，避免一次性解码全量缩略图。
const galleryPageSize = 20;


/// 顶部“最近图片(↓)”子列表的相册分类。
final class GalleryAlbum {
  const GalleryAlbum({
    required this.id,
    required this.name,
    required this.isRecent,
    required this.isVideoOnly,
    this.entity,
  });

  final String id;
  final String name;

  /// “最近图片”（全部照片+视频，时间倒序）。
  final bool isRecent;

  /// “本地视频”（仅视频）。
  final bool isVideoOnly;

  final AssetPathEntity? entity;
}

/// 相册数据源：基于 photo_manager **分页**读取本地图片/视频。
///
/// - 网格一律按**创建时间倒序**（最新创建的显示在最上方）；
/// - 缩略图统一按 200px 解码，压缩图/原图仅在发送时按需读取；
/// - 视频发送默认压缩（480p，减轻服务器负担），原图模式有 20MB 上限。
final FilterOptionGroup _sortedByCreateDateDesc = FilterOptionGroup(
  orders: [OrderOption(type: OrderOptionType.createDate, asc: false)],
);

class DeviceGallerySource {
  /// 顶部子列表：最近图片（默认）+ 本地视频 + 其余本地图库分类
  /// （Camera、Screenshots、Download…）。
  static Future<List<GalleryAlbum>> loadAlbums() async {
    if (!await _ensurePermission()) throw GalleryPermissionDenied();
    final List<AssetPathEntity> recent;
    final List<AssetPathEntity> videos;
    final List<AssetPathEntity> folders;
    try {
      recent = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        onlyAll: true,
        filterOption: _sortedByCreateDateDesc,
      );
      videos = await PhotoManager.getAssetPathList(
        type: RequestType.video,
        onlyAll: true,
        filterOption: _sortedByCreateDateDesc,
      );
      folders = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        onlyAll: false,
        filterOption: _sortedByCreateDateDesc,
      );
    } catch (_) {
      throw GalleryUnavailable('(相册索引读取失败)');
    }
    return [
      if (recent.isNotEmpty)
        const GalleryAlbum(id: 'recent', name: '最近图片', isRecent: true, isVideoOnly: false),
      if (videos.isNotEmpty)
        const GalleryAlbum(id: 'videos', name: '本地视频', isRecent: false, isVideoOnly: true),
      ...[
        for (final folder in folders)
          if (!folder.isAll)
            GalleryAlbum(
                id: folder.id, name: folder.name, isRecent: false, isVideoOnly: false, entity: folder),
      ],
    ];
  }

  /// 按相册构造分页器（null = 最近图片）。
  static DeviceGalleryPager pagerFor(GalleryAlbum? album) =>
      DeviceGalleryPager(album: album?.entity);

  static Future<bool> _ensurePermission() async {
    final permission = await PhotoManager.requestPermissionExtend(
      requestOption: PermissionRequestOption(
        androidPermission: AndroidPermission(
          type: RequestType.common,
          mediaLocation: false,
        ),
        iosAccessLevel: IosAccessLevel.readWrite,
      ),
    );
    return permission.hasAccess;
  }
}

/// 生产相册分页器：按时间倒序逐页读取（最新创建的在前）。
class DeviceGalleryPager {
  DeviceGalleryPager({AssetPathEntity? album, RequestType type = RequestType.common})
      : _fixedAlbum = album,
        _type = type;

  final AssetPathEntity? _fixedAlbum;
  final RequestType _type;

  AssetPathEntity? _album;
  int _loaded = 0;
  bool _exhausted = false;

  bool get hasMore => !_exhausted;

  /// 请求相册权限并定位目标相册（时间倒序：最新创建的显示在最上方）。
  Future<void> ensureAccess() async {
    if (!await DeviceGallerySource._ensurePermission()) {
      throw GalleryPermissionDenied();
    }
    if (_album != null) return;
    if (_fixedAlbum != null) {
      _album = _fixedAlbum;
      return;
    }
    List<AssetPathEntity> albums;
    try {
      albums = await PhotoManager.getAssetPathList(
        type: _type,
        onlyAll: true,
        filterOption: _sortedByCreateDateDesc,
      );
    } catch (_) {
      throw GalleryUnavailable('(相册索引读取失败)');
    }
    if (albums.isEmpty) {
      _exhausted = true;
      return;
    }
    _album = albums.first;
  }

  /// 加载下一页（时间倒序）；相册耗尽后返回空列表。
  Future<List<GalleryPhoto>> loadNextPage(
      {int pageSize = galleryPageSize}) async {
    if (_exhausted) return const [];
    final album = _album;
    if (album == null) {
      await ensureAccess();
    }
    final target = _album;
    if (target == null || _exhausted) return const [];
    final assets = await target.getAssetListRange(
      start: _loaded,
      end: _loaded + pageSize,
    );
    if (assets.length < pageSize) _exhausted = true;
    _loaded += assets.length;
    final photos = <GalleryPhoto>[];
    for (final asset in assets) {
      final isVideo = asset.type == AssetType.video;
      // GIF 走原图字节才能保持动画（压缩重编码会退化成静态图）。
      final isGif = asset.mimeType == 'image/gif';
      final thumbnail = await asset.thumbnailDataWithSize(
        const ThumbnailSize.square(200),
      );
      // 缩略图解码失败不丢弃条目（MKV/AVI 等冷门容器也要可选可发）：
      // 网格以占位底色渲染，选择与发送仍走原始字节。
      final thumbBytes = Uint8List.fromList(thumbnail ?? const []);
      // MIME 按系统媒体库真实值透传（MP4/MOV/MKV/AVI…），不再一律 mp4。
      final mimeType = asset.mimeType ??
          (isVideo ? 'video/mp4' : 'image/jpeg');
      photos.add(
        GalleryPhoto(
          id: asset.id,
          thumbnail: thumbBytes,
          isVideo: isVideo,
          duration: isVideo ? asset.videoDuration : null,
          mimeType: mimeType,
          compressedBytes: isVideo
              ? () => _readCompressedVideo(asset)
              : isGif
                  ? () async {
                      // GIF 原样发送：保留逐帧动画。
                      final data = await asset.originBytes;
                      if (data == null) throw StateError('gif unavailable');
                      return Uint8List.fromList(data);
                    }
                  : () async {
                      final data = await asset.thumbnailDataWithSize(
                        const ThumbnailSize(1280, 1280),
                        quality: 80,
                      );
                      if (data == null) {
                        throw StateError('compressed image unavailable');
                      }
                      return Uint8List.fromList(data);
                    },
          originalBytes: () async {
            final data = await asset.originBytes;
            if (data == null) {
              throw StateError(isVideo ? 'original video unavailable' : 'original image unavailable');
            }
            return Uint8List.fromList(data);
          },
          originalSizeBytes: isVideo
              ? () async {
                  final file = await asset.originFile;
                  return file?.length() ?? 0;
                }
              : null,
          compressedPreviewFile:
              isVideo ? () async => _resolveVideoRendition(asset) : null,
          posterBytes: isVideo ? () async => _videoPosterBytes(asset) : null,
        ),
      );
    }
    return photos;
  }

  /// 视频封面帧：约 480px、保持画面比例（非方形裁剪）。
  /// 生成失败返回 null（消息可不附带封面，接收端回退占位图）。
  Future<Uint8List?> _videoPosterBytes(AssetEntity asset) async {
    try {
      final poster = await asset.thumbnailDataWithSize(
        const ThumbnailSize(480, 480),
        quality: 85,
      );
      return poster == null ? null : Uint8List.fromList(poster);
    } catch (_) {
      return null;
    }
  }

  /// 视频压缩：预览播放与发送复用同一份产物，不二次转码。
  /// 策略统一收敛在 `transcodeForChat`（480p，≥50% 减量目标，降档重试）；
  /// 这里只负责缓存与 >20MB 兜底拦截（回退原文件过大时拒绝发送）。
  Future<VideoRendition> _resolveVideoRendition(AssetEntity asset) async {
    final cached = _compressedVideoFiles[asset.id];
    if (cached != null) return cached;
    final origin = await asset.originFile;
    if (origin == null) throw StateError('video unavailable');
    final originSize = await origin.length();
    final rendition = await transcodeForChat(origin);
    if (!rendition.usedCompressed && originSize > maxOriginalVideoBytes) {
      // 原文件过大压不动的情况不应静默把巨大文件推给服务器。
      throw StateError('compressed video unavailable');
    }
    return _compressedVideoFiles[asset.id] = rendition;
  }

  final Map<String, VideoRendition> _compressedVideoFiles = {};

  /// 读取已解析的压缩产物信息（预览页用于提示回退状态）；未解析过返回 null。
  VideoRendition? cachedVideoRendition(String assetId) =>
      _compressedVideoFiles[assetId];

  Future<Uint8List> _readCompressedVideo(AssetEntity asset) async =>
      (await _resolveVideoRendition(asset)).file.readAsBytes();
}

/// 兼容入口：一次性加载首页（供旧调用方过渡）；新代码请使用 [DeviceGalleryPager]。
Future<List<GalleryPhoto>> loadDeviceGalleryPhotos({int limit = 600}) async {
  final pager = DeviceGalleryPager();
  await pager.ensureAccess();
  final all = <GalleryPhoto>[];
  while (pager.hasMore && all.length < limit) {
    all.addAll(await pager.loadNextPage());
  }
  return all;
}
