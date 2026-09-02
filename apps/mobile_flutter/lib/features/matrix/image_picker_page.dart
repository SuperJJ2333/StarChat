import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../ui/components/wechat_scaffold.dart';
import 'device_gallery_source.dart';
import 'gallery_video_preview.dart';
import '../../ui/foundation/wechat_tokens.dart';

/// 选择逻辑（纯逻辑，可测）：有序多选、上限 9 张、可取消勾选。
final class GallerySelection extends ChangeNotifier {
  GallerySelection({this.maxCount = 9});

  final int maxCount;
  final List<String> _orderedIds = [];
  bool original = false;
  String? overflowHint;

  static const overflowMessage = '最多选择9张图片';

  List<String> get orderedIds => List.unmodifiable(_orderedIds);
  int get count => _orderedIds.length;
  bool get canSend => _orderedIds.isNotEmpty;

  bool isSelected(String id) => _orderedIds.contains(id);

  /// 切换相册时清空勾选（跨相册勾选顺序无意义）。
  void clear() {
    _orderedIds.clear();
    overflowHint = null;
    notifyListeners();
  }

  /// 返回 true 表示状态发生变化；超过上限时返回 false 并设置提示。
  bool toggle(String id) {
    overflowHint = null;
    if (_orderedIds.contains(id)) {
      _orderedIds.remove(id);
      notifyListeners();
      return true;
    }
    if (_orderedIds.length >= maxCount) {
      overflowHint = overflowMessage;
      notifyListeners();
      return false;
    }
    _orderedIds.add(id);
    notifyListeners();
    return true;
  }

  /// 勾选顺序即发送顺序（第几张）。
  int orderOf(String id) => _orderedIds.indexOf(id) + 1;
}

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

/// 全屏图片预览页：点击缩略图进入，展示高清图（1280px 按需解码）；
/// 右下角“选择”胶囊与网格左上角圆圈等效，同步选中态。
final class _GalleryPreviewPage extends StatefulWidget {
  const _GalleryPreviewPage({
    required this.photo,
    required this.selected,
    required this.onToggle,
  });

  final GalleryPhoto photo;
  final bool selected;
  final VoidCallback onToggle;

  @override
  State<_GalleryPreviewPage> createState() => _GalleryPreviewPageState();
}

final class _GalleryPreviewPageState extends State<_GalleryPreviewPage> {
  late bool selected = widget.selected;
  late final Future<Uint8List> _bytes = widget.photo.compressedBytes();

  @override
  Widget build(BuildContext context) {
    return WeChatPageScaffold.bare(
      backgroundColor: CupertinoColors.black,
      child: SafeArea(
        child: Stack(children: [
          Positioned.fill(
            child: FutureBuilder<Uint8List>(
              future: _bytes,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CupertinoActivityIndicator());
                }
                return GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: InteractiveViewer(
                    maxScale: 4,
                    child: Center(
                      child: Image.memory(snapshot.data!, fit: BoxFit.contain),
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            child: CupertinoButton(
              key: const Key('gallery-preview-back'),
              padding: EdgeInsets.zero,
              onPressed: () => Navigator.pop(context),
              child: const Icon(CupertinoIcons.chevron_back,
                  size: 22, color: CupertinoColors.white),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 24,
            child: CupertinoButton(
              key: const Key('gallery-preview-select'),
              color: selected
                  ? WeChatColors.brandPrimary
                  : CupertinoColors.systemGrey5.withValues(alpha: .28),
              borderRadius: BorderRadius.circular(18),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              onPressed: () {
                widget.onToggle();
                setState(() => selected = !selected);
              },
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (selected) ...[
                  const Icon(CupertinoIcons.check_mark,
                      size: 14, color: CupertinoColors.white),
                  const SizedBox(width: 4),
                ],
                Text(selected ? '已选择' : '选择',
                    style: const TextStyle(
                        fontSize: 14, color: CupertinoColors.white)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

/// 相册子列表加载器（顶部“最近图片(↓)”下拉），可注入测试桩。
typedef GalleryAlbumsLoader = Future<List<GalleryAlbum>> Function();

/// 按相册构造分页器（null = 最近图片），可注入测试桩。
typedef GalleryPagerFactory = DeviceGalleryPager Function(GalleryAlbum? album);

/// 微信风格的图片/视频选择页：每行 4 张缩略图、左上角圆点勾选（含序号）、
/// 顶部“最近图片(↓)”相册子列表（本地视频/Camera/Screenshots…）、
/// 左下角“原图”开关（默认关闭，发送压缩内容；勾选后视频超 20MB 拦截）、
/// 最多 9 项。
///
/// 加载策略：**分段懒加载**——首屏仅加载最新 20 张 200px 缩略图，
/// 滚动接近末尾时按序追加一页并在底部展示“加载中…”提示，
/// 避免一次性解码全部照片造成卡顿。
final class ImagePickerPage extends StatefulWidget {
  const ImagePickerPage({
    super.key,
    this.pagerBuilder = DeviceGalleryPager.new,
    this.maxCount = 9,
    this.albumsLoader = DeviceGallerySource.loadAlbums,
    this.pagerFactory = DeviceGallerySource.pagerFor,
  });

  final DeviceGalleryPager Function() pagerBuilder;
  final int maxCount;
  final GalleryAlbumsLoader albumsLoader;
  final GalleryPagerFactory pagerFactory;

  @override
  State<ImagePickerPage> createState() => _ImagePickerPageState();
}

final class _ImagePickerPageState extends State<ImagePickerPage>
    with WidgetsBindingObserver {
  final selection = GallerySelection(maxCount: 9);
  late DeviceGalleryPager pager = widget.pagerBuilder();
  final scrollController = ScrollController();
  List<GalleryPhoto> photos = const [];
  bool loading = true;
  bool loadingMore = false;
  bool hasMore = false;
  bool permissionDenied = false;
  String? loadError;

  /// 相册子列表与当前选中项（默认“最近图片”）。
  List<GalleryAlbum> albums = const [];
  GalleryAlbum? selectedAlbum;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    unawaited(_loadAlbums());
  }

  Future<void> _loadAlbums() async {
    try {
      final loaded = await widget.albumsLoader();
      if (!mounted) return;
      setState(() => albums = loaded);
    } catch (_) {
      // 子列表加载失败不影响默认“最近图片”浏览。
    }
  }

  /// 切换相册：重建分页器并重载（勾选清空，避免跨相册误发）。
  Future<void> _selectAlbum(GalleryAlbum album) async {
    if (album.id == (selectedAlbum?.id ?? 'recent')) return;
    selection.clear();
    setState(() {
      selectedAlbum = album;
      pager = widget.pagerFactory(album.isRecent ? null : album);
    });
    await _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    scrollController.dispose();
    super.dispose();
  }

  // 用户从系统设置返回（授权/改选照片范围）后自动重新检查并加载。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        (permissionDenied || loadError != null)) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      loadError = null;
      loadMoreFailed = false;
    });
    try {
      photos = const [];
      final firstPage = <GalleryPhoto>[...await pager.loadNextPage()];
      if (!mounted) return;
      setState(() {
        photos = firstPage;
        loading = false;
        permissionDenied = false;
        hasMore = pager.hasMore || firstPage.isNotEmpty;
      });
      // 首屏若未填满一屏，立即预取下一页，保证滚动无缝。
      if (firstPage.length < 12) unawaited(_loadMore());
    } on GalleryPermissionDenied {
      if (!mounted) return;
      setState(() {
        loading = false;
        permissionDenied = true;
        photos = const [];
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        loading = false;
        loadError = failure is GallerySourceError
            ? failure.message
            : '相册加载失败，请重试';
      });
    }
  }

  /// 滚动预取：可见范围接近已加载末尾时按序追加一页（20 张缩略图）。
  /// 失败时置 [loadMoreFailed]，页脚提供“点击重试”（弱网可恢复）。
  Future<void> _loadMore() async {
    if (loadingMore || !hasMore || loading) return;
    setState(() {
      loadingMore = true;
      loadMoreFailed = false;
    });
    try {
      final next = await pager.loadNextPage();
      if (!mounted) return;
      setState(() {
        photos = [...photos, ...next];
        loadingMore = false;
        hasMore = pager.hasMore;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loadingMore = false;
        loadMoreFailed = true;
      });
    }
  }

  bool loadMoreFailed = false;

  void _maybePrefetch(int index) {
    if (index >= photos.length - 4 && !_prefetchQueued) {
      // 不能在 build 期 setState：排到帧末触发追加加载。
      _prefetchQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _prefetchQueued = false;
        if (mounted) unawaited(_loadMore());
      });
    }
  }

  bool _prefetchQueued = false;

  Future<void> _openSystemSettings() async {
    await PhotoManager.openSetting();
  }

  void _toggle(GalleryPhoto photo) {
    selection.toggle(photo.id);
    setState(() {});
  }

  Future<void> _send() async {
    final chosen = [
      for (final id in selection.orderedIds)
        photos.firstWhere((photo) => photo.id == id),
    ];
    // “原图”模式下单个视频不得超过 20MB：拦截发送并提示
    //（关闭“原图”走压缩发送不受此限）。
    if (selection.original) {
      for (final item in chosen) {
        if (!item.isVideo) continue;
        final size = await item.originalSizeBytes?.call() ?? 0;
        if (size > maxOriginalVideoBytes) {
          if (!mounted) return;
          await showCupertinoDialog<void>(
            context: context,
            builder: (dialogContext) => CupertinoAlertDialog(
              key: const Key('image-picker-video-limit-dialog'),
              title: const Text('视频过大'),
              content: const Text(
                  '单个视频超过20MB，无法以原图发送。请关闭“原图”后重试'
                  '（将自动压缩后发送）。'),
              actions: [
                CupertinoDialogAction(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('知道了'),
                ),
              ],
            ),
          );
          return;
        }
      }
    }
    if (!mounted) return;
    Navigator.pop(context, (photos: chosen, original: selection.original));
  }

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final barColor = dark ? WeChatColors.darkSurface : WeChatColors.lightSurface;
    return WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
        transitionBetweenRoutes: false,
        middle: CupertinoButton(
          key: const Key('image-picker-album-button'),
          minimumSize: Size.zero,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          onPressed: _showAlbumPicker,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(_albumLabel,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            const Icon(CupertinoIcons.chevron_down, size: 14),
          ]),
        ),
      ),
      backgroundColor:
          dark ? WeChatColors.darkPageBackground : WeChatColors.lightPageBackground,
      child: SafeArea(
        child: Column(children: [
          Expanded(child: _grid(dark)),
          _bottomBar(barColor),
        ]),
      ),
    );
  }

  String get _albumLabel => selectedAlbum?.name ?? '最近图片';

  /// 顶部“最近图片(↓)”子列表：默认选中“最近图片”，
  /// 含“本地视频”与本地图库分类（Camera/Screenshots/Download…）。
  Future<void> _showAlbumPicker() async {
    if (albums.isEmpty) await _loadAlbums();
    if (!mounted || albums.isEmpty) return;
    final picked = await showCupertinoModalPopup<GalleryAlbum>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        key: const Key('image-picker-album-sheet'),
        title: const Text('选择相册'),
        actions: [
          for (final album in albums)
            CupertinoActionSheetAction(
              key: Key('image-picker-album-${album.id}'),
              onPressed: () => Navigator.pop(sheetContext, album),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(album.name),
                  if ((selectedAlbum?.id ?? 'recent') == album.id) ...[
                    const SizedBox(width: 6),
                    const Icon(CupertinoIcons.check_mark,
                        size: 15, color: WeChatColors.brandPrimary),
                  ],
                ],
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheetContext),
          child: const Text('取消'),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await _selectAlbum(picked);
  }

  Widget _grid(bool dark) {
    if (loading) {
      return const Center(child: CupertinoActivityIndicator());
    }
    if (permissionDenied) {
      return Center(
        child: Padding(
          key: const Key('image-picker-permission-denied'),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(CupertinoIcons.photo_on_rectangle,
                  size: 44, color: WeChatColors.textTertiary),
              const SizedBox(height: 14),
              Text(
                '未获得相册权限',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: WeChatColors.resolveTextPrimary(context)),
              ),
              const SizedBox(height: 8),
              Text(
                '需要在系统设置中允许畅聊访问全部照片（或选择部分照片）后，'
                    '返回本页即可自动加载。',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: WeChatColors.textSecondary),
              ),
              const SizedBox(height: 18),
              CupertinoButton(
                key: const Key('image-picker-open-settings'),
                color: WeChatColors.brandPrimary,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                onPressed: _openSystemSettings,
                child: const Text('前往设置',
                    style: TextStyle(color: CupertinoColors.white)),
              ),
            ],
          ),
        ),
      );
    }
    if (loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(loadError!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13, color: WeChatColors.textSecondary)),
            const SizedBox(height: 12),
            CupertinoButton(
              onPressed: _load,
              child: const Text('重试',
                  style: TextStyle(color: WeChatColors.brandPrimary)),
            ),
          ],
        ),
      );
    }
    final showFooter = loadingMore || hasMore;
    return GridView.builder(
      key: const Key('image-picker-grid'),
      controller: scrollController,
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
        childAspectRatio: 0.82,
      ),
      itemCount: photos.length + (showFooter ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= photos.length) {
          return _gridFooter();
        }
        _maybePrefetch(index);
        final photo = photos[index];
        return GestureDetector(
          key: Key('image-picker-item-${photo.id}'),
          behavior: HitTestBehavior.opaque,
          // 点击预览区域=放大查看；选中只由左上角圆圈切换，二者严格分离。
          onTap: () => _openPreview(photo),
          child: Stack(fit: StackFit.expand, children: [
            Image.memory(photo.thumbnail,
                key: Key('image-picker-thumb-${photo.id}'),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => const ColoredBox(
                    color: WeChatColors.textTertiary)),
            if (photo.isVideo)
              Positioned(
                left: 6,
                bottom: 6,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0x99000000),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(CupertinoIcons.play_fill,
                        size: 9, color: CupertinoColors.white),
                    const SizedBox(width: 3),
                    Text(_formatDuration(photo.duration),
                        style: const TextStyle(
                            fontSize: 10, color: CupertinoColors.white)),
                  ]),
                ),
              ),
            Positioned(
              top: 6,
              left: 6,
              child: _checkCircle(photo),
            ),
          ]),
        );
      },
    );
  }

  /// 网格页脚：加载中转圈 / 失败可点重试 / 可加载更多提示。
  Widget _gridFooter() {
    if (loadMoreFailed) {
      return CupertinoButton(
        key: const Key('image-picker-loadmore-retry'),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        onPressed: _loadMore,
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(CupertinoIcons.refresh, size: 16,
                color: WeChatColors.brandPrimary),
            SizedBox(height: 6),
            Text('加载失败，点击重试',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11, color: WeChatColors.textSecondary)),
          ],
        ),
      );
    }
    if (loadingMore) {
      return const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CupertinoActivityIndicator(radius: 9),
          SizedBox(height: 6),
          Text('加载中…',
              style: TextStyle(
                  fontSize: 11, color: WeChatColors.textSecondary)),
        ],
      );
    }
    return const Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(CupertinoIcons.chevron_down, size: 14,
            color: WeChatColors.textTertiary),
        SizedBox(height: 6),
        Text('上拉加载更多',
            style: TextStyle(
                fontSize: 11, color: WeChatColors.textTertiary)),
      ],
    );
  }

  /// 点击缩略图 → 全屏预览；视频进入视频预览页（可播放），
  /// 图片进入图片预览页；预览页内可同步切换选中态。
  Future<void> _openPreview(GalleryPhoto photo) async {
    if (photo.isVideo) {
      final previewFile = photo.compressedPreviewFile;
      if (previewFile != null) {
        await Navigator.of(context, rootNavigator: true).push(
          CupertinoPageRoute(
            fullscreenDialog: true,
            builder: (_) => GalleryVideoPreviewPage(
              loadRendition: previewFile,
              thumbnailBytes: photo.thumbnail,
              duration: photo.duration,
              selected: selection.isSelected(photo.id),
              onToggle: () {
                setState(() => _toggle(photo));
              },
            ),
          ),
        );
        if (mounted) setState(() {});
        return;
      }
    }
    await Navigator.of(context, rootNavigator: true).push(
      CupertinoPageRoute(
        fullscreenDialog: true,
        builder: (_) => _GalleryPreviewPage(
          photo: photo,
          selected: selection.isSelected(photo.id),
          onToggle: () {
            setState(() => _toggle(photo));
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) return '0:00';
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Widget _checkCircle(GalleryPhoto photo) {
    final selected = selection.isSelected(photo.id);
    return AnimatedScale(
      key: Key('image-picker-check-${photo.id}'),
      scale: selected ? 1.0 : 0.92,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _toggle(photo),
        child: Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected
                ? WeChatColors.brandPrimary
                : const Color(0x66000000),
            border: Border.all(
              color: selected
                  ? WeChatColors.brandPrimary
                  : CupertinoColors.white,
              width: 1.5,
            ),
          ),
          child: selected
              ? const Icon(CupertinoIcons.check_mark,
                  size: 14, color: CupertinoColors.white)
              : const SizedBox.shrink(),
        ),
      ),
    );
  }

  Widget _bottomBar(Color barColor) {
    return Container(
      key: const Key('image-picker-bottom-bar'),
      color: barColor,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(children: [
        // 左下角"原图"开关：默认关闭，勾选后发送原图。
        const Text('原图', style: TextStyle(fontSize: 15)),
        const SizedBox(width: 6),
        SizedBox(
          height: 28,
          child: CupertinoSwitch(
            key: const Key('image-picker-original-switch'),
            value: selection.original,
            activeTrackColor: WeChatColors.brandPrimary,
            onChanged: (value) => setState(() => selection.original = value),
          ),
        ),
        const Spacer(),
        if (selection.overflowHint != null)
          Text(
            selection.overflowHint!,
            style: const TextStyle(fontSize: 12, color: WeChatColors.danger),
          ),
        const SizedBox(width: 8),
        CupertinoButton(
          key: const Key('image-picker-send'),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          color: selection.canSend
              ? WeChatColors.brandPrimary
              : WeChatColors.divider,
          minimumSize: const Size(0, 36),
          onPressed: selection.canSend ? _send : null,
          child: Text(
            selection.canSend ? '发送(${selection.count})' : '发送',
            style: TextStyle(
              fontSize: 15,
              color: selection.canSend
                  ? CupertinoColors.white
                  : WeChatColors.textTertiary,
            ),
          ),
        ),
      ]),
    );
  }
}
