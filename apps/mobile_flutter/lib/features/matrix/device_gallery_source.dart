import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import 'video_poster_extractor.dart';
import 'gif_image_policy.dart';
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
    this.firstFrame,
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

  /// 规格#4：视频首帧懒加载（磁盘缓存命中即回，未命中经全局
  /// [videoFirstFrameStore] 有界并发抽帧并落盘；成功结果内存缓存，
  /// 失败按退避有限重试）。仅视频条目提供。
  final Future<Uint8List?> Function()? firstFrame;

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

/// 首屏页大小：先返回可见网格（约 3~4 列 × 3~4 行）的 12 张，
/// 用户立即可以交互，剩余按 20/页追加。
const galleryFirstPageSize = 12;

/// 缩略图有界并发解码上限：防止一次性把整页解码任务塞满解码线程
/// 与内存（顺序解码太慢、无上限并发会瞬时峰值）。
const galleryDecodeConcurrency = 3;

/// 有界并发执行缩略图解码任务：保持输入顺序；单张失败回退空占位
/// （与旧的 `thumbnail ?? const []` 语义一致）。
Future<List<Uint8List>> decodeThumbnailsBounded(
  List<Future<Uint8List?> Function()> tasks, {
  int maxConcurrent = galleryDecodeConcurrency,
}) async {
  final results = List<Uint8List?>.filled(tasks.length, null);
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final index = next++;
      if (index >= tasks.length) return;
      try {
        results[index] = await tasks[index]();
      } catch (_) {
        results[index] = null;
      }
    }
  }

  final workers = [
    for (var i = 0; i < maxConcurrent && i < tasks.length; i++) worker(),
  ];
  await Future.wait(workers);
  return [
    for (final result in results) result ?? Uint8List.fromList(const []),
  ];
}

/// 会话级相册访问缓存：权限（仅缓存"已授权"）与相册索引在同一会话内
/// 复用——重进选图页不再重复请求权限、不再重复扫描相册索引。
///
/// 缓存失效时机（三处显式触发）：
/// 1. 权限范围变化（部分授权 ↔ 全部照片 ↔ 撤销）：[DeviceGallerySource]
///    在页面 resume 时用 `getPermissionState` 探测比对，变化即 [invalidate]；
/// 2. 系统媒体库变化：选图页挂载期间注册 photo_manager 变更回调，
///    变化即 [invalidate] 并重载当前相册；
/// 3. 会话结束：缓存为进程内存态，应用退出即丢弃；登出换账号时
///    [invalidate] 由调用方触发。
final class GalleryAccessCache {
  GalleryAccessCache._();

  static final GalleryAccessCache shared = GalleryAccessCache._();
  static final GalleryAccessCache photos = GalleryAccessCache._();
  static GalleryAccessCache forMode(bool photosOnly) =>
      photosOnly ? photos : shared;
  static void invalidateAll() {
    shared.invalidate();
    photos.invalidate();
  }

  bool? _permissionGranted;

  /// 授权范围指纹（'full' / 'limited'）：部分授权与全部照片可见的
  /// 媒体集合不同，范围变化必须失效索引缓存，不得把有限授权当作
  /// 完整媒体库访问。
  String? _permissionScope;
  List<GalleryAlbum>? _albums;

  /// "最近图片"（common）与"本地视频"（video）都是 entity 为 null 的
  /// 虚拟相册，定位结果必须按 RequestType 分桶缓存——共用一个桶时，
  /// 先打开"最近图片"再切"本地视频"会复用 common 相册，绕过视频查询。
  final Map<RequestType, AssetPathEntity?> _recentAlbumsByType = {};

  void invalidate() {
    _permissionGranted = null;
    _permissionScope = null;
    _albums = null;
    _recentAlbumsByType.clear();
  }

  /// 当前缓存的授权范围是否与 [scope] 一致（探测用，不修改状态）。
  bool matchesPermissionScope(String? scope) =>
      _permissionGranted == true && _permissionScope == scope;

  /// 探测到授权范围变化（resume 时调用）：整体失效缓存并返回 true。
  bool invalidateIfScopeChanged(String? scope) {
    if (matchesPermissionScope(scope)) return false;
    invalidate();
    return true;
  }

  /// 只缓存已授权结果：被拒绝不缓存（用户从设置页返回后应重新请求）。
  /// [scope] 为本次授权范围指纹；与上次不一致时授权需重新确认。
  Future<bool> ensurePermission(
    Future<bool> Function() request, {
    String? scope,
  }) async {
    if (_permissionGranted == true && _permissionScope == scope) return true;
    final granted = await request();
    if (granted) {
      _permissionGranted = true;
      _permissionScope = scope;
    }
    return granted;
  }

  Future<List<GalleryAlbum>> loadAlbums(
    Future<List<GalleryAlbum>> Function() load,
  ) async {
    final cached = _albums;
    if (cached != null) return cached;
    return _albums = await load();
  }

  /// 按 [type] 分桶缓存"最近/全部"相册定位结果。
  Future<AssetPathEntity?> recentAlbum(
    RequestType type,
    Future<AssetPathEntity?> Function() load,
  ) async {
    if (_recentAlbumsByType.containsKey(type)) return _recentAlbumsByType[type];
    return _recentAlbumsByType[type] = await load();
  }
}

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
  // MIUI 的视频记录可能没有宽高；不能把元数据缺失当作无效视频。
  videoOption:
      const FilterOption(sizeConstraint: SizeConstraint(ignoreSize: true)),
  orders: [OrderOption(type: OrderOptionType.createDate, asc: false)],
);

/// 相册 → 资源查询类型映射（MIUI 修复）："本地视频"是虚拟相册
/// （entity 为 null），必须用 [RequestType.video] 才能定位到视频
/// 媒体库；此前漏传 type 退化为 common 混合列表。
RequestType requestTypeForAlbum(GalleryAlbum? album) =>
    album != null && album.isVideoOnly ? RequestType.video : RequestType.common;

class DeviceGallerySource {
  /// 顶部子列表：最近图片（默认）+ 本地视频 + 其余本地图库分类
  /// （Camera、Screenshots、Download…）。权限与索引结果经会话级缓存
  /// 复用（GalleryAccessCache.shared）。
  static Future<List<GalleryAlbum>> loadAlbums(
      {bool photosOnly = false}) async {
    if (!await _ensurePermission(photosOnly: photosOnly)) {
      throw GalleryPermissionDenied();
    }
    return GalleryAccessCache.forMode(photosOnly)
        .loadAlbums(() => _scanAlbums(photosOnly: photosOnly));
  }

  static Future<List<GalleryAlbum>> _scanAlbums(
      {bool photosOnly = false}) async {
    final List<AssetPathEntity> recent;
    final List<AssetPathEntity> videos;
    final List<AssetPathEntity> folders;
    try {
      recent = await PhotoManager.getAssetPathList(
        type: photosOnly ? RequestType.image : RequestType.common,
        onlyAll: true,
        filterOption: _sortedByCreateDateDesc,
      );
      videos = photosOnly
          ? <AssetPathEntity>[]
          : await PhotoManager.getAssetPathList(
              type: RequestType.video,
              onlyAll: true,
              filterOption: _sortedByCreateDateDesc,
            );
      folders = await PhotoManager.getAssetPathList(
        type: photosOnly ? RequestType.image : RequestType.common,
        onlyAll: false,
        filterOption: _sortedByCreateDateDesc,
      );
    } catch (_) {
      throw GalleryUnavailable('(相册索引读取失败)');
    }
    return [
      if (recent.isNotEmpty)
        const GalleryAlbum(
            id: 'recent', name: '最近图片', isRecent: true, isVideoOnly: false),
      if (videos.isNotEmpty)
        const GalleryAlbum(
            id: 'videos', name: '本地视频', isRecent: false, isVideoOnly: true),
      ...[
        for (final folder in folders)
          if (!folder.isAll)
            GalleryAlbum(
                id: folder.id,
                name: folder.name,
                isRecent: false,
                isVideoOnly: false,
                entity: folder),
      ],
    ];
  }

  /// 按相册构造分页器（null = 最近图片）。
  static DeviceGalleryPager pagerFor(GalleryAlbum? album,
          {bool photosOnly = false}) =>
      DeviceGalleryPager(
          album: album?.entity,
          type: photosOnly ? RequestType.image : requestTypeForAlbum(album));

  static Future<bool> _requestPermission({bool photosOnly = false}) async {
    final permission = await PhotoManager.requestPermissionExtend(
      requestOption: PermissionRequestOption(
        androidPermission: AndroidPermission(
          type: photosOnly ? RequestType.image : RequestType.common,
          mediaLocation: false,
        ),
        iosAccessLevel: IosAccessLevel.readWrite,
      ),
    );
    _lastKnownScopes[photosOnly] = permissionScopeOf(permission);
    return permission.hasAccess;
  }

  static Future<bool> _ensurePermission({bool photosOnly = false}) =>
      GalleryAccessCache.forMode(photosOnly).ensurePermission(
        () => _requestPermission(photosOnly: photosOnly),
        scope: _lastKnownScopes[photosOnly],
      );

  /// 最近一次权限请求的授权范围（null = 尚未请求）。
  static final Map<bool, String?> _lastKnownScopes = {};

  /// 最近一次权限请求/探测的授权范围（'full'/'limited'/null=未知）。
  /// UI 据此在 limited 时提供"管理可见照片/视频"入口（审计注记：
  /// Android 14+ 允许仅授权选定媒体，需要明确入口让用户重选）。
  static String? get lastKnownPermissionScope => _lastKnownScopes[false];
  static String? permissionScopeFor({bool photosOnly = false}) =>
      _lastKnownScopes[photosOnly];

  /// 测试注入。
  @visibleForTesting
  static set lastKnownPermissionScopeForTest(String? value) =>
      _lastKnownScopes[false] = value;

  /// 授权范围指纹：部分授权（limited）与全部授权可见的媒体集合不同。
  static String? permissionScopeOf(PermissionState state) =>
      state.isAuth ? 'full' : (state.isLimited ? 'limited' : null);

  /// 页面 resume 时探测权限范围是否变化（只查询，不弹窗）。
  ///
  /// 返回 true 表示范围已变化且缓存已失效（调用方应重新加载）；
  /// 查询失败按未变化处理（不阻塞浏览）。
  static Future<bool> permissionScopeChanged({bool photosOnly = false}) async {
    PermissionState state;
    try {
      state = await PhotoManager.getPermissionState(
        requestOption: PermissionRequestOption(
          androidPermission: AndroidPermission(
            type: photosOnly ? RequestType.image : RequestType.common,
            mediaLocation: false,
          ),
          iosAccessLevel: IosAccessLevel.readWrite,
        ),
      );
    } catch (_) {
      return false;
    }
    final scope = permissionScopeOf(state);
    _lastKnownScopes[photosOnly] = scope;
    if (GalleryAccessCache.forMode(photosOnly).matchesPermissionScope(scope)) {
      return false;
    }
    GalleryAccessCache.invalidateAll();
    return true;
  }
}

/// 生产相册分页器：按时间倒序逐页读取（最新创建的在前）。
class DeviceGalleryPager {
  DeviceGalleryPager(
      {AssetPathEntity? album, RequestType type = RequestType.common})
      : _fixedAlbum = album,
        _type = type;

  final AssetPathEntity? _fixedAlbum;
  final RequestType _type;

  AssetPathEntity? _album;
  int _loaded = 0;
  bool _exhausted = false;

  bool get hasMore => !_exhausted;

  /// 已解析的目标相册（测试/诊断用）。
  @visibleForTesting
  AssetPathEntity? get resolvedAlbum => _album;

  /// 请求相册权限并定位目标相册（时间倒序：最新创建的显示在最上方）。
  /// 权限与"最近"相册定位结果经会话级缓存复用。
  Future<void> ensureAccess() async {
    if (!await DeviceGallerySource._ensurePermission(
        photosOnly: _type == RequestType.image)) {
      throw GalleryPermissionDenied();
    }
    if (_album != null) return;
    if (_fixedAlbum != null) {
      _album = _fixedAlbum;
      return;
    }
    final album = await GalleryAccessCache.forMode(_type == RequestType.image)
        .recentAlbum(_type, () async {
      try {
        final albums = await PhotoManager.getAssetPathList(
          type: _type,
          onlyAll: true,
          filterOption: _sortedByCreateDateDesc,
        );
        return albums.isEmpty ? null : albums.first;
      } catch (_) {
        throw GalleryUnavailable('(相册索引读取失败)');
      }
    });
    if (album == null) {
      _exhausted = true;
      return;
    }
    _album = album;
  }

  /// 加载下一页（时间倒序）；相册耗尽后返回空列表。
  ///
  /// 首屏默认只取 [galleryFirstPageSize]（12）张（覆盖可见网格），
  /// 后续页默认 20；缩略图按 [galleryDecodeConcurrency] 有界并发解码。
  Future<List<GalleryPhoto>> loadNextPage(
      {int pageSize = galleryPageSize}) async {
    if (_exhausted) return const [];
    final album = _album;
    if (album == null) {
      await ensureAccess();
    }
    final target = _album;
    if (target == null || _exhausted) return const [];
    final isFirstPage = _loaded == 0;
    final count = isFirstPage && pageSize == galleryPageSize
        ? galleryFirstPageSize
        : pageSize;
    final assets = await target.getAssetListRange(
      start: _loaded,
      end: _loaded + count,
    );
    if (assets.length < count) _exhausted = true;
    _loaded += assets.length;
    // 规格#4：图片有界解码整页缩略图；**视频不等待系统缩略图**
    // （部分 ROM 上视频缩略图极慢，导致整页等待）——立即返回空占位，
    // 首帧由 firstFrame 闭包按 cell 懒加载（缓存命中秒回）。
    final thumbnails = await decodeThumbnailsBounded([
      for (final asset in assets)
        () => asset.type == AssetType.video
            ? Future<Uint8List?>.value(Uint8List(0))
            : asset.thumbnailDataWithSize(const ThumbnailSize.square(200)),
    ]);
    final photos = <GalleryPhoto>[];
    for (var i = 0; i < assets.length; i++) {
      final asset = assets[i];
      final isVideo = asset.type == AssetType.video;
      // 缩略图解码失败不丢弃条目（MKV/AVI 等冷门容器也要可选可发）：
      // 网格以占位底色渲染，选择与发送仍走原始字节。
      final thumbBytes = thumbnails[i];
      // MIME 按系统媒体库真实值透传（MP4/MOV/MKV/AVI…），不再一律 mp4。
      final mimeType = asset.mimeType ?? (isVideo ? 'video/mp4' : 'image/jpeg');
      photos.add(
        GalleryPhoto(
          id: asset.id,
          thumbnail: thumbBytes,
          isVideo: isVideo,
          duration: isVideo ? asset.videoDuration : null,
          mimeType: mimeType,
          compressedBytes: isVideo
              ? () => _readCompressedVideo(asset)
              : () => _readImage(asset, compressed: true),
          originalBytes: () => isVideo
              ? _readOriginal(asset)
              : _readImage(asset, compressed: false),
          originalSizeBytes: isVideo
              ? () async {
                  final file = await asset.originFile;
                  return file?.length() ?? 0;
                }
              : null,
          compressedPreviewFile:
              isVideo ? () async => _resolveVideoRendition(asset) : null,
          posterBytes: isVideo ? () async => _videoPosterBytes(asset) : null,
          firstFrame: isVideo ? () => videoFirstFrameStore.load(asset) : null,
        ),
      );
    }
    return photos;
  }

  Future<Uint8List> _readOriginal(AssetEntity asset, {File? file}) async {
    if (file != null) return file.readAsBytes();
    Uint8List? bytes;
    try {
      bytes = await asset.originBytes;
    } catch (_) {
      // Some galleries expose a file but cannot return originBytes.
    }
    if (bytes != null) return bytes;
    final origin = file ?? await asset.originFile;
    if (origin == null) throw StateError('original media unavailable');
    return origin.readAsBytes();
  }

  Future<Uint8List> _readImage(AssetEntity asset,
      {required bool compressed}) async {
    File? file;
    try {
      file = await asset.originFile;
    } catch (_) {
      // Fall back to the platform byte API for cloud-only assets.
    }
    Uint8List? original;
    bool gif;
    if (file != null) {
      final handle = await file.open();
      try {
        final header = await handle.read(10);
        gif = isGifBytes(header);
        if (gif) {
          validateGifForSend(header);
          if (await handle.length() > maxChatGifBytes) {
            throw const FormatException('GIF 过大，请选择不超过 20MB、400 万像素的动图');
          }
        }
      } finally {
        await handle.close();
      }
    } else {
      original = await _readOriginal(asset);
      gif = isGifBytes(original);
    }
    if (gif || !compressed) {
      final bytes = original ?? await _readOriginal(asset, file: file);
      validateGifForSend(bytes);
      return bytes;
    }
    final bytes = await asset.thumbnailDataWithSize(
      const ThumbnailSize(1280, 1280),
      quality: 80,
    );
    if (bytes == null) throw StateError('compressed image unavailable');
    return bytes;
  }

  /// 视频封面帧：多时间点抽取（200/500/1000/2000ms）+ 近黑帧跳过，
  /// 兜底回退 photo_manager 原始封面（≈480px、保持比例）。
  /// 全部失败返回 null（消息可不附带封面，接收端回退占位图）。
  Future<Uint8List?> _videoPosterBytes(AssetEntity asset) async {
    try {
      final origin = await asset.originFile;
      if (origin != null) {
        final poster = await extractVideoPoster(origin.path);
        if (poster != null && poster.isNotEmpty) return poster;
      }
    } catch (_) {
      // 抽帧失败走回退。
    }
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

/// 视频首帧采样位置：按时长选取合法多时间点（片头 200ms 常为黑场，
/// 多点位 + 近黑帧跳过可显著提高可用封面率）。
///
/// - 候选点必须落在时长内（留 50ms 余量防止越界取帧失败）；
/// - 视频短于全部候选点时回退到时长中点（短视频没有选择的余地）；
/// - 时长未知（null/0）按候选点原样尝试。
List<int> samplePositionsFor(
  Duration? duration, [
  List<int> candidates = const [200, 500, 1000, 2000],
]) {
  final durationMs = duration?.inMilliseconds ?? 0;
  if (durationMs <= 0) return candidates;
  final legal = [
    for (final position in candidates)
      if (position < durationMs - 50) position
  ];
  if (legal.isNotEmpty) return legal;
  final midpoint = (durationMs ~/ 2).clamp(0, durationMs - 1);
  return [midpoint];
}

/// 规格#4：视频首帧懒加载（磁盘缓存 video_first_frame_cache）。
///
/// key = sha256(path|id|durationMs|size)：对整文件做 sha256 比抽帧更贵，
/// 以 路径+时长+大小 组合作内容寻址代理（文件被修改/替换后任一变化
/// 即得新 key，旧缓存自然失效）。
///
/// 抽帧复用 [extractVideoPoster] 的多时间点 + 近黑帧跳过能力，采样
/// 位置由 [samplePositionsFor] 按视频时长选取。
/// [fetch] 注入抽帧实现（默认 video_compress），测试替身用。
Future<Uint8List?> loadVideoFirstFrame(
  AssetEntity asset, {
  Future<Uint8List?> Function(String path, int positionMs)? fetch,
  Future<Directory> Function()? cacheDir,
  List<int> Function(Duration?)? positionsFor,
  bool ignoreCache = false,
}) async {
  try {
    final origin = await asset.originFile;
    if (origin == null) return null;
    final dirFactory = cacheDir ?? getApplicationDocumentsDirectory;
    final dir = Directory(
        '${(await dirFactory()).path}${Platform.pathSeparator}video_first_frame_cache');
    await dir.create(recursive: true);
    final key = sha256
        .convert(utf8.encode(
            '${origin.path}|${asset.id}|${asset.videoDuration}|${await origin.length()}'))
        .toString();
    final cacheFile = File('${dir.path}${Platform.pathSeparator}$key.jpg');
    // ignoreCache：字节级损坏恢复（存在但不可解码）——跳过磁盘读强制
    // 重抽，成功后覆盖缓存文件。
    if (!ignoreCache && await cacheFile.exists()) {
      // 缓存损坏防御：空文件（写入中断/磁盘异常）删除后重新抽帧，
      // 不得把空字节当命中永远占住。
      final cached = await cacheFile.readAsBytes();
      if (cached.isNotEmpty) return cached;
      try {
        await cacheFile.delete();
      } catch (_) {
        // 删除失败也继续抽帧（写回时覆盖）。
      }
    }
    final positions = (positionsFor ?? samplePositionsFor)(asset.videoDuration);
    final frame = await extractVideoPoster(
      origin.path,
      fetch: fetch,
      positionsMs: positions,
    );
    if (frame == null || frame.isEmpty) return null;
    await cacheFile.writeAsBytes(frame, flush: true);
    return frame;
  } catch (_) {
    return null; // 首帧失败不阻塞网格（保持占位，由协调器有限重试）。
  }
}

/// 视频首帧加载协调器：把"每格直接抽帧"收敛为全局受控的任务流。
///
/// - **有界并发**：底层解码任务同时最多 [maxConcurrent] 个（快速滚动
///   不会瞬时堆积大量解码任务，整页展示不被阻塞——网格先渲染占位）；
/// - **并发合并**：同一资源的并发请求共享同一个 in-flight Future；
/// - **成功缓存**：成功结果内存 memoize（磁盘缓存由
///   [loadVideoFirstFrame] 负责），后续请求零成本；
/// - **失败不占坑**：失败结果绝不缓存，按 [retryBackoff] 退避有限重试
///   （[maxAttempts] 上限），退避窗口内的调用快速返回 null 而不排队
///   解码——既不会"每次 build 都重试"，也不会把失败永久 memoize；
/// - **超时按失败处理**：单任务超过 [timeout] 即记失败。底层原生任务
///   可能仍在运行（video_compress 无取消接口），但 [maxAttempts] 上限
///   约束每个资源最多提交这么多次原生任务，不会无限重复提交；
/// - **手动重试**：预算耗尽后 [resetById] 清零，UI 提供重试入口。
final class VideoFirstFrameStore {
  VideoFirstFrameStore({
    this.maxConcurrent = 2,
    this.timeout = const Duration(seconds: 10),
    this.maxAttempts = 3,
    this.retryBackoff = const Duration(seconds: 2),
    Future<Uint8List?> Function(AssetEntity asset)? loader,
    Future<Uint8List?> Function(AssetEntity asset)? forceLoader,
    DateTime Function()? clock,
  })  : loader = loader ?? loadVideoFirstFrame,
        forceLoader = forceLoader ??
            ((asset) => loadVideoFirstFrame(asset, ignoreCache: true)),
        _clock = clock ?? (() => DateTime.now());

  static const maxConcurrentDefault = 2;

  final int maxConcurrent;
  final Duration timeout;
  final int maxAttempts;
  final Duration retryBackoff;

  /// 视频首帧实际抽帧实现（测试替身注入；生产走 [loadVideoFirstFrame]
  /// 磁盘缓存链路）。命名参数 [ignoreDiskCache] 供损坏恢复重抽使用。
  final Future<Uint8List?> Function(AssetEntity asset) loader;
  final Future<Uint8List?> Function(AssetEntity asset)? forceLoader;
  final DateTime Function() _clock;

  final _successes = <String, Future<Uint8List?>>{};
  final _inFlight = <String, Future<Uint8List?>>{};
  final _attempts = <String, int>{};
  final _nextAllowedAt = <String, DateTime>{};
  final _queue = <_FirstFrameJob>[];
  int _active = 0;

  /// 读取（自动合并并发、遵守退避与预算）。
  Future<Uint8List?> load(AssetEntity asset) {
    final key = asset.id;
    final success = _successes[key];
    if (success != null && !_forceExtract.contains(key)) return success;
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final forced = _forceExtract.contains(key);
    if (!forced && (_attempts[key] ?? 0) >= maxAttempts) {
      return Future.value(null);
    }
    if (!forced) {
      final next = _nextAllowedAt[key];
      if (next != null && _clock().isBefore(next)) return Future.value(null);
    }

    final completer = Completer<Uint8List?>();
    final future = completer.future;
    _inFlight[key] = future;
    _queue.add(_FirstFrameJob(this, key, asset, completer));
    _drain();
    return future;
  }

  void _drain() {
    while (_active < maxConcurrent && _queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      _active++;
      job.run().whenComplete(() {
        _active--;
        _drain();
      });
    }
  }

  void _recordFailure(String key) {
    final attempts = (_attempts[key] ?? 0) + 1;
    _attempts[key] = attempts;
    _nextAllowedAt[key] = _clock().add(retryBackoff * attempts);
  }

  /// 重试预算是否已耗尽（UI 显示重试入口的依据）。
  bool retriesExhaustedById(String assetId) =>
      (_attempts[assetId] ?? 0) >= maxAttempts;

  /// 手动重试入口：清零该资源的失败预算与退避。
  void resetById(String assetId) {
    _attempts.remove(assetId);
    _nextAllowedAt.remove(assetId);
  }

  /// 损坏恢复入口（审计 P2，gallery-call-review）：磁盘缓存字节存在
  /// 但不可解码（Image.memory errorBuilder 触发）时，UI 调用本方法后
  /// 重新 load——绕过磁盘缓存强制重抽并覆盖缓存文件，成功后恢复正常
  /// 缓存路径。同时清零失败预算与退避。
  void invalidateById(String assetId) {
    resetById(assetId);
    _forceExtract.add(assetId);
  }

  /// 强制重抽集合（损坏恢复；load 命中后清除）。
  final _forceExtract = <String>{};

  /// 正在执行的底层解码任务数（诊断/测试）。
  int get activeExtractions => _active;

  /// 排队中的任务数（诊断/测试）。
  int get queuedExtractions => _queue.length;
}

final class _FirstFrameJob {
  _FirstFrameJob(this.store, this.key, this.asset, this.completer);

  final VideoFirstFrameStore store;
  final String key;
  final AssetEntity asset;
  final Completer<Uint8List?> completer;

  Future<void> run() async {
    Uint8List? frame;
    // 损坏恢复：强制重抽走 ignoreCache 路径（跳过磁盘读，重抽后覆盖）。
    final effectiveLoader = store._forceExtract.contains(key)
        ? (store.forceLoader ?? store.loader)
        : store.loader;
    try {
      frame = await effectiveLoader(asset).timeout(store.timeout);
    } catch (_) {
      // 超时/加载异常一律按失败记账（预算上限约束原生任务提交次数）。
    }
    if (completer.isCompleted) return;
    if (frame != null && frame.isNotEmpty) {
      store._successes[key] = Future.value(frame);
      store._attempts.remove(key);
      store._nextAllowedAt.remove(key);
      store._forceExtract.remove(key);
      completer.complete(frame);
    } else {
      store._recordFailure(key);
      completer.complete(null);
    }
    store._inFlight.remove(key);
  }
}

/// 全局首帧协调器实例（进程内所有选图会话共享有界并发预算）。
final videoFirstFrameStore = VideoFirstFrameStore();

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
