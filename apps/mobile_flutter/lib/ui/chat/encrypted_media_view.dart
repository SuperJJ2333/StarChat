import '../../features/matrix/media_thumbnail.dart';
import '../../features/matrix/gif_image_policy.dart';
import 'contain_image_bubble.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import '../foundation/wechat_tokens.dart';
import '../components/wechat_scaffold.dart';
import 'chat_forward_picker_page.dart';
import '../../core/gallery_save_access.dart';

/// 原图大小展示格式：≥1MB 用 MB（10MB 以上取整），否则用 KB。
/// 大小由每次加载到的真实字节数动态计算，不使用事件元数据。
String formatMediaSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    final mb = bytes / (1024 * 1024);
    return '${mb >= 10 ? mb.round() : double.parse(mb.toStringAsFixed(1))}M';
  }
  final kb = (bytes / 1024).ceil();
  return '${kb < 1 ? 1 : kb}K';
}

/// 加密图片消息缩略图。
///
/// 加载优先级：**缩略图优先**——调用方提供 [loadThumbnail] 时先取
/// 发送端生成的 ≤800px/≤100KB 压缩演绎版，消息气泡只下载小图即可渲染；
/// 缩略图缺失（旧消息）或加载失败时回退 [load] 全量加载，行为兼容。
///
/// 防滑动抽动的两个关键约束：
/// 1. 占位与成图使用**完全相同**的固定尺寸（200×150，BoxFit.cover）——
///   之前加载完成按原图比例展开，列表锚点跳变导致滚动抽动；
/// 2. 调用方传入会话级缓存字节（[initialBytes]）时同步渲染，滚动反复
///   进入视口不再触发重复解密/读盘。
///
/// 点击进入全屏查看器；[forwardTargets]/[forwardTo] 提供“转发”能力，
/// 缺省时查看器隐藏转发按钮（下载始终可用）。
final class EncryptedImageMessage extends StatefulWidget {
  const EncryptedImageMessage({
    super.key,
    required this.load,
    this.loadThumbnail,
    this.originalSizeHint,
    this.initialBytes,
    this.forwardTargets = const [],
    this.forwardTo,
    this.onForward,
  });

  final Future<Uint8List> Function() load;

  /// 压缩缩略图加载器；返回 null 表示无缩略图（回退 [load]）。
  final Future<Uint8List?> Function()? loadThumbnail;

  /// 原图字节数提示（消息 info.size），供查看器“查看原图 xK/M”展示。
  final int? originalSizeHint;
  final Uint8List? initialBytes;

  static const thumbnailWidth = 200.0;
  static const thumbnailHeight = 150.0;

  /// 可转发的目标会话（房间 id → 展示名），由会话页注入。
  final List<({String roomId, String title})> forwardTargets;

  /// 转发动作：把当前图片转发到目标会话。
  final Future<void> Function(String roomId)? forwardTo;
  final Future<void> Function()? onForward;

  @override
  State<EncryptedImageMessage> createState() => _EncryptedImageMessageState();
}

final class _EncryptedImageMessageState extends State<EncryptedImageMessage> {
  late Future<Uint8List> bytes = widget.initialBytes != null
      ? SynchronousFuture<Uint8List>(widget.initialBytes!)
      : _loadPreferredBytes();

  /// 缩略图优先：小图快速渲染；null/失败回退全量。
  Future<Uint8List> _loadPreferredBytes() {
    final thumbnailLoader = widget.loadThumbnail;
    if (thumbnailLoader == null) return widget.load();
    return thumbnailLoader().then(
      (thumbnail) => thumbnail ?? widget.load(),
      onError: (_) => widget.load(),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
        future: bytes,
        builder: (_, snapshot) {
          if (snapshot.hasError) {
            return CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () {
                setState(() {
                  bytes = _loadPreferredBytes();
                });
              },
              child: const Text('图片加载失败，点击重试'),
            );
          }
          if (!snapshot.hasData) {
            return const SizedBox(
              width: EncryptedImageMessage.thumbnailWidth,
              height: EncryptedImageMessage.thumbnailHeight,
              child: Center(child: CupertinoActivityIndicator()),
            );
          }
          return GestureDetector(
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              CupertinoPageRoute(
                builder: (_) => ImageViewerPage(
                  previewBytes: snapshot.data!,
                  originalSizeHint: widget.originalSizeHint,
                  loadOriginal: widget.load,
                  forwardTargets: widget.forwardTargets,
                  forwardTo: widget.forwardTo,
                  onForward: widget.onForward,
                ),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(WeChatRadius.bubble),
              child: SizedBox(
                width: EncryptedImageMessage.thumbnailWidth,
                height: EncryptedImageMessage.thumbnailHeight,
                child: Image(
                  image: boundedChatImageProvider(snapshot.data!),
                  fit: BoxFit.cover,
                  // 预览按 720px 解码：显著降低内存与解码耗时，
                  // 全屏查看时由查看器按原图字节另行渲染。
                  gaplessPlayback: true,
                ),
              ),
            ),
          );
        },
      );
}

/// 全屏查看图片页（所有图片消息共用，收发两侧一致）：
/// - 占位阶段只渲染缩略图/预览字节；左下角「查看原图 xxK/M」按钮，
///   大小按每次加载到的原图字节数动态计算，点击后**异步**加载原图，
///   加载完成渲染原图并显示实际像素尺寸；
/// - 右下角「下载」「转发」圆形操作按钮：深灰（#555555）背景、白色图标；
///   下载保存到系统相册，转发调起会话选择并加密转发；
/// - 双击/捏合缩放、点击图片区域关闭。
final class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    super.key,
    required this.previewBytes,
    this.originalSizeHint,
    this.loadOriginal,
    this.forwardTargets = const [],
    this.forwardTo,
    this.onForward,
  });

  /// 占位缩略图/预览字节：点击“查看原图”前仅展示它。
  final Uint8List previewBytes;

  /// 原图字节数提示（来自消息 info.size）；未知时以预览字节兜底。
  final int? originalSizeHint;

  /// 原图异步加载器；缺省时预览字节即原图，隐藏“查看原图”入口。
  final Future<Uint8List> Function()? loadOriginal;

  /// 可转发的目标会话（房间 id → 展示名）。
  final List<({String roomId, String title})> forwardTargets;

  /// 转发动作：把当前图片转发到目标会话。
  final Future<void> Function(String roomId)? forwardTo;
  final Future<void> Function()? onForward;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

final class _ImageViewerPageState extends State<ImageViewerPage> {
  Uint8List? originalBytes;
  bool loadingOriginal = false;
  bool originalFailed = false;
  ({int width, int height})? dimensions;
  bool forwarding = false;
  String? hint;

  /// 原图大小按本次实际字节动态计算；未加载时以提示值/预览字节兜底。
  int get originalSizeBytes {
    final loaded = originalBytes;
    if (loaded != null) return loaded.lengthInBytes;
    final hint = widget.originalSizeHint;
    if (hint != null) return hint;
    return widget.previewBytes.lengthInBytes;
  }

  Future<void> _loadOriginal() async {
    final loader = widget.loadOriginal;
    if (loader == null || loadingOriginal || originalBytes != null) return;
    setState(() {
      loadingOriginal = true;
      originalFailed = false;
    });
    try {
      final bytes = await loader();
      ({int width, int height})? decoded;
      try {
        final size = await decodeImageDimensions(bytes);
        if (size != null) decoded = (width: size.$1, height: size.$2);
      } catch (_) {
        // 尺寸解码失败不影响原图展示。
      }
      if (!mounted) return;
      setState(() {
        originalBytes = bytes;
        dimensions = decoded;
        loadingOriginal = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loadingOriginal = false;
        originalFailed = true;
        hint = '原图加载失败，点击「查看原图」重试';
      });
    }
  }

  Future<void> _download() async {
    try {
      await ensureGallerySaveAccess();
      final bytes = originalBytes ??
          await (widget.loadOriginal?.call() ??
              Future<Uint8List>.value(widget.previewBytes));
      final result = await PhotoManager.editor.saveImage(
        bytes,
        filename: 'changliao-${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      if (!mounted) return;
      setState(() {
        hint = result.id.isNotEmpty ? '已保存到相册' : '保存失败，请稍后重试';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => hint = gallerySaveErrorMessage(error));
    }
  }

  Future<void> _forward() async {
    if (forwarding) return;
    setState(() => forwarding = true);
    try {
      if (widget.onForward != null) {
        await widget.onForward!();
      } else if (widget.forwardTo != null) {
        await Navigator.of(context, rootNavigator: true)
            .push(CupertinoPageRoute(
          builder: (_) => ChatForwardPickerPage(
            contentPreview: '[图片]',
            candidates: [
              for (final t in widget.forwardTargets)
                ChatForwardCandidate(
                    roomId: t.roomId,
                    title: t.title,
                    avatar: const Icon(CupertinoIcons.chat_bubble))
            ],
            recentRoomIds: const [],
            onForward: (ids) async {
              for (final id in ids) {
                await widget.forwardTo!(id);
              }
            },
          ),
        ));
      }
    } catch (_) {
      if (mounted) setState(() => hint = '转发失败，请重试');
    } finally {
      if (mounted) setState(() => forwarding = false);
    }
  }

  String get _originalLabel {
    if (originalBytes == null) {
      if (loadingOriginal) return '原图加载中…';
      if (originalFailed) return '原图加载失败，点击重试';
      return '查看原图 ${formatMediaSize(originalSizeBytes)}';
    }
    final dims = dimensions;
    return dims == null
        ? '已展示原图 ${formatMediaSize(originalSizeBytes)}'
        : '已展示原图 ${dims.width}×${dims.height}';
  }

  @override
  Widget build(BuildContext context) {
    final displayBytes = originalBytes ?? widget.previewBytes;
    return WeChatPageScaffold.navigation(
      backgroundColor: CupertinoColors.black,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.black,
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.pop(context),
          child: const Icon(CupertinoIcons.xmark,
              size: 22, color: CupertinoColors.white),
        ),
        transitionBetweenRoutes: false,
      ),
      child: SafeArea(
        child: Stack(
          children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Center(
                child: InteractiveViewer(
                  maxScale: 4,
                  child: Image(
                    image: boundedChatImageProvider(displayBytes,
                        maxEdge: isGifBytes(displayBytes) ? 720 : 2048),
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
            if (loadingOriginal)
              const Center(child: CupertinoActivityIndicator()),
            if (widget.loadOriginal != null)
              Positioned(
                left: 16,
                bottom: 24,
                child: CupertinoButton(
                  key: const Key('viewer-view-original'),
                  color: CupertinoColors.systemGrey5.withValues(alpha: .28),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  onPressed: originalBytes == null ? _loadOriginal : null,
                  child: Text(
                    _originalLabel,
                    style: const TextStyle(
                        fontSize: 13, color: CupertinoColors.white),
                  ),
                ),
              ),
            Positioned(
              right: 16,
              bottom: 24,
              child: Column(
                children: [
                  ViewerRoundAction(
                    key: const Key('viewer-download'),
                    icon: CupertinoIcons.cloud_download,
                    label: '下载',
                    onPressed: _download,
                  ),
                  const SizedBox(height: 14),
                  if (widget.forwardTo != null || widget.onForward != null)
                    ViewerRoundAction(
                      key: const Key('viewer-forward'),
                      icon: CupertinoIcons.paperplane,
                      label: '转发',
                      onPressed: forwarding ? null : _forward,
                    ),
                ],
              ),
            ),
            if (hint != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 96,
                child: ViewerStatusHint(message: hint!),
              ),
          ],
        ),
      ),
    );
  }
}

/// 右下角圆形操作按钮：深灰（#555555）背景 + 白色图标（产品规格色）。
final class ViewerRoundAction extends StatelessWidget {
  const ViewerRoundAction({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: onPressed,
            child: Container(
              width: 46,
              height: 46,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF555555),
              ),
              child: Icon(icon, size: 20, color: CupertinoColors.white),
            ),
          ),
          const SizedBox(height: 4),
          Text(label,
              style:
                  const TextStyle(fontSize: 12, color: CupertinoColors.white)),
        ],
      );
}

/// 图片和视频查看器共用的操作结果提示。
final class ViewerStatusHint extends StatelessWidget {
  const ViewerStatusHint({super.key, required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Center(
          child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
            color: CupertinoColors.systemGrey6.withValues(alpha: .3),
            borderRadius: BorderRadius.circular(18)),
        child: Text(message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: CupertinoColors.white)),
      ));
}
