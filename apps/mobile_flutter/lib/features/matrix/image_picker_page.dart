import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../ui/components/wechat_scaffold.dart';
import 'device_gallery_source.dart';
import 'gallery_video_preview.dart';

export 'device_gallery_source.dart' show GalleryPhoto;
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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

  /// 请求批次：相册切换即递增。进行中的旧请求完成后发现批次已变，
  /// 直接丢弃结果——旧相册的列表/加载态/错误态不得覆盖新相册。
  int _loadEpoch = 0;

  /// 相册子列表与当前选中项（默认“最近图片”）。
  List<GalleryAlbum> albums = const [];
  GalleryAlbum? selectedAlbum;

  /// 系统媒体库变化回调（挂载期间注册；变化即失效会话缓存并重载）。
  void _onGalleryChanged(MethodCall call) {
    GalleryAccessCache.shared.invalidate();
    if (mounted) unawaited(_reloadAfterExternalChange());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    unawaited(_loadAlbums());
    unawaited(_observeGalleryChanges());
  }

  Future<void> _observeGalleryChanges() async {
    try {
      PhotoManager.addChangeCallback(_onGalleryChanged);
      await PhotoManager.startChangeNotify();
    } catch (_) {
      // 变更监听不可用（权限/平台差异）：不影响浏览，仅失去自动刷新。
    }
  }

  /// 媒体库变化/权限范围变化后的重载：清空勾选避免跨集合误发。
  Future<void> _reloadAfterExternalChange() async {
    selection.clear();
    setState(() {}); // 仅刷勾选态；列表由 _load 重建
    await _load();
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
    try {
      PhotoManager.removeChangeCallback(_onGalleryChanged);
      PhotoManager.stopChangeNotify();
    } catch (_) {
      // 未注册成功时移除无害。
    }
    scrollController.dispose();
    super.dispose();
  }

  // 用户从系统设置返回（授权/改选照片范围）后自动重新检查并加载：
  // - 此前被拒/加载失败 → 直接重载；
  // - 授权范围变化（部分照片 ↔ 全部照片 ↔ 撤销）→ 失效会话缓存后重载，
  //   不得把有限授权的媒体集合当作完整媒体库继续展示。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (permissionDenied || loadError != null) {
      unawaited(_load());
      return;
    }
    unawaited(_reloadIfScopeChanged());
  }

  Future<void> _reloadIfScopeChanged() async {
    try {
      if (await DeviceGallerySource.permissionScopeChanged()) {
        await _reloadAfterExternalChange();
      }
    } catch (_) {
      // 探测失败不阻塞浏览。
    }
  }

  Future<void> _load() async {
    final epoch = ++_loadEpoch;
    final activePager = pager;
    setState(() {
      loading = true;
      loadError = null;
      loadMoreFailed = false;
    });
    try {
      photos = const [];
      final firstPage = <GalleryPhoto>[...await activePager.loadNextPage()];
      // 请求批次已变（用户切到其他相册）：旧结果直接丢弃。
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        photos = firstPage;
        loading = false;
        permissionDenied = false;
        hasMore = pager.hasMore || firstPage.isNotEmpty;
      });
      // 首屏若未填满一屏，立即预取下一页，保证滚动无缝。
      if (firstPage.length < 12) unawaited(_loadMore());
    } on GalleryPermissionDenied {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        loading = false;
        permissionDenied = true;
        photos = const [];
      });
    } catch (failure) {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        loading = false;
        loadError =
            failure is GallerySourceError ? failure.message : '相册加载失败，请重试';
      });
    }
  }

  /// 滚动预取：可见范围接近已加载末尾时按序追加一页（20 张缩略图）。
  /// 失败时置 [loadMoreFailed]，页脚提供“点击重试”（弱网可恢复）。
  Future<void> _loadMore() async {
    if (loadingMore || !hasMore || loading) return;
    final epoch = _loadEpoch;
    final activePager = pager;
    setState(() {
      loadingMore = true;
      loadMoreFailed = false;
    });
    try {
      final next = await activePager.loadNextPage();
      // 请求批次或分页器已换（切相册/外部重载）：旧页不得混入新列表。
      if (!mounted || epoch != _loadEpoch || !identical(activePager, pager)) {
        return;
      }
      setState(() {
        photos = [...photos, ...next];
        loadingMore = false;
        hasMore = activePager.hasMore;
      });
    } catch (_) {
      if (!mounted || epoch != _loadEpoch) return;
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
              content: const Text('单个视频超过20MB，无法以原图发送。请关闭“原图”后重试'
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
    final barColor =
        dark ? WeChatColors.darkSurface : WeChatColors.lightSurface;
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
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            const Icon(CupertinoIcons.chevron_down, size: 14),
          ]),
        ),
      ),
      backgroundColor: dark
          ? WeChatColors.darkPageBackground
          : WeChatColors.lightPageBackground,
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
            // 规格#4：视频缩略图懒加载——立即渲染占位，首帧就绪只更新
            // 本 cell（成功内存缓存、失败退避重试、预算耗尽显重试入口）。
            if (photo.isVideo)
              _VideoFirstFrameCell(photo: photo)
            else
              Image.memory(photo.thumbnail,
                  key: Key('image-picker-thumb-${photo.id}'),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) =>
                      const ColoredBox(color: WeChatColors.textTertiary)),
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
            Icon(CupertinoIcons.refresh,
                size: 16, color: WeChatColors.brandPrimary),
            SizedBox(height: 6),
            Text('加载失败，点击重试',
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 11, color: WeChatColors.textSecondary)),
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
              style:
                  TextStyle(fontSize: 11, color: WeChatColors.textSecondary)),
        ],
      );
    }
    return const Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(CupertinoIcons.chevron_down,
            size: 14, color: WeChatColors.textTertiary),
        SizedBox(height: 6),
        Text('上拉加载更多',
            style: TextStyle(fontSize: 11, color: WeChatColors.textTertiary)),
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
            color:
                selected ? WeChatColors.brandPrimary : const Color(0x66000000),
            border: Border.all(
              color:
                  selected ? WeChatColors.brandPrimary : CupertinoColors.white,
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

/// 视频格首帧 cell（规格#4 加固）：
/// - 立即渲染占位（抽帧不阻塞整页展示）；
/// - 成功首帧直接显示（全局协调器内存缓存，重复 build 零成本）；
/// - 失败由协调器按退避自动有限重试（退避窗口内快速返回占位）；
/// - 预算耗尽时显示明确重试入口；封面失败不删条目、不阻断选择，
///   预览/发送仍走原始文件路径。
final class _VideoFirstFrameCell extends StatefulWidget {
  const _VideoFirstFrameCell({required this.photo});

  final GalleryPhoto photo;

  @override
  State<_VideoFirstFrameCell> createState() => _VideoFirstFrameCellState();
}

final class _VideoFirstFrameCellState extends State<_VideoFirstFrameCell> {
  Future<Uint8List?>? _future;

  @override
  void didUpdateWidget(covariant _VideoFirstFrameCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 条目实例变化（翻页重建/相册切换）：重新走一次加载（命中缓存即回）。
    if (!identical(oldWidget.photo, widget.photo)) _future = null;
  }

  void _retry() {
    videoFirstFrameStore.resetById(widget.photo.id);
    setState(() => _future = null);
  }

  @override
  Widget build(BuildContext context) {
    final load = widget.photo.firstFrame;
    if (load == null) return _placeholder(showRetry: false);
    final future = _future ??= load();
    return FutureBuilder<Uint8List?>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data!.isNotEmpty) {
          return Image.memory(
            snapshot.data!,
            key: Key('image-picker-frame-${widget.photo.id}'),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            // 缓存字节损坏（写一半/位翻转）：按失败占位，不闪退不黑卡。
            errorBuilder: (_, __, ___) => _placeholder(showRetry: false),
          );
        }
        // 本次尝试已结束且无可用帧：显示重试入口。自动重试的节流由全局
        // 协调器（退避窗口内快速返回，不解码）保证，不会"每次 build 都重试"。
        final done = snapshot.connectionState == ConnectionState.done;
        return _placeholder(showRetry: done);
      },
    );
  }

  Widget _placeholder({required bool showRetry}) => ColoredBox(
        color: const Color(0xFF3A3A3A),
        child: Center(
          child: showRetry
              ? CupertinoButton(
                  key: Key('image-picker-frame-retry-${widget.photo.id}'),
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  onPressed: _retry,
                  child: const Icon(CupertinoIcons.arrow_clockwise,
                      size: 22, color: Color(0xCCFFFFFF)),
                )
              : const Icon(CupertinoIcons.videocam_fill,
                  size: 22, color: Color(0x80FFFFFF)),
        ),
      );
}
