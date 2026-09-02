import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'device_gallery_source.dart';

/// 相册视频预览页：点击图片页中的视频条目进入。
/// - 优先播放**压缩产物文件**（480p 减缩版，与发送复用同一份，预览即所见即所发）；
///   压缩产物准备阶段显示**进度百分比**（转码进行中）；
/// - 压缩版不可用时**回退原始视频**并给出明确提示（不静默）；
/// - 准备失败提供「重试」；
/// - 播放/暂停、进度与时长展示；
/// - 右下角“选择/已选择”胶囊与网格左上角圆圈等效；
/// - 播放器初始化失败（冷门容器解码不支持等）降级为
///   “缩略图 + 时长 + 可选择可发送”，不阻塞发送流程。
final class GalleryVideoPreviewPage extends StatefulWidget {
  const GalleryVideoPreviewPage({
    super.key,
    required this.loadRendition,
    required this.thumbnailBytes,
    required this.duration,
    required this.selected,
    required this.onToggle,
  });

  /// 解析压缩产物（480p 减缩版；不可用时回退原始视频并在结果中说明）。
  final Future<VideoRendition> Function() loadRendition;
  final Uint8List thumbnailBytes;
  final Duration? duration;
  final bool selected;
  final VoidCallback onToggle;

  @override
  State<GalleryVideoPreviewPage> createState() =>
      _GalleryVideoPreviewPageState();
}

final class _GalleryVideoPreviewPageState
    extends State<GalleryVideoPreviewPage> {
  VideoPlayerController? _controller;
  Future<bool>? _initFuture;
  bool selected = false;

  /// 压缩产物准备进度（0~1；无进度事件时为 null，展示活动指示器）。
  double? _prepareProgress;
  Subscription? _progressSubscription;

  /// 回退原始视频的明确提示（展示数秒后自动消失）。
  String? _fallbackNotice;
  Timer? _noticeTimer;

  /// 准备阶段文案（压缩中/解码中）。
  String _prepareLabel = '正在准备压缩版…';

  @override
  void initState() {
    super.initState();
    selected = widget.selected;
    _initFuture = _initialize();
  }

  Future<bool> _initialize() async {
    _prepareProgress = null;
    _prepareLabel = '正在准备压缩版…';
    _fallbackNotice = null;
    try {
      // 先订阅进度流再触发转码，确保不丢事件。
      _progressSubscription?.unsubscribe();
      _progressSubscription = VideoCompress.compressProgress$.subscribe(
        (value) {
          final normalized = value > 1 ? value / 100 : value;
          if (mounted &&
              normalized >= 0 &&
              normalized <= 1 &&
              _controller == null) {
            setState(() => _prepareProgress = normalized);
          }
        },
      );
      final rendition = await widget.loadRendition();
      if (!mounted) return false;
      if (!rendition.usedCompressed && rendition.fallbackNotice != null) {
        _showNotice(rendition.fallbackNotice!);
      }
      _prepareLabel = '正在解码视频…';
      final controller = VideoPlayerController.file(rendition.file);
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return false;
      }
      setState(() => _controller = controller);
      await controller.play();
      return true;
    } catch (_) {
      if (mounted) setState(() {});
      return false; // 解码不支持：降级静态预览。
    } finally {
      _progressSubscription?.unsubscribe();
      _progressSubscription = null;
    }
  }

  void _showNotice(String message) {
    _noticeTimer?.cancel();
    setState(() => _fallbackNotice = message);
    _noticeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _fallbackNotice = null);
    });
  }

  /// 「重试」：重置状态后重新解析压缩产物并初始化播放器。
  void _retry() {
    _controller?.dispose();
    _controller = null;
    setState(() {
      _initFuture = _initialize();
    });
  }

  Future<void> _togglePlay() async {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _noticeTimer?.cancel();
    _progressSubscription?.unsubscribe();
    _controller?.dispose();
    super.dispose();
  }

  String _format(Duration? duration) {
    if (duration == null) return '00:00';
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return WeChatPageScaffold.bare(
      backgroundColor: CupertinoColors.black,
      child: SafeArea(
        child: Stack(children: [
          Positioned.fill(
            child: FutureBuilder<bool>(
              future: _initFuture,
              builder: (context, snapshot) {
                final controller = _controller;
                if (controller != null && controller.value.isInitialized) {
                  return GestureDetector(
                    onTap: _togglePlay,
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: controller.value.aspectRatio,
                        child: VideoPlayer(controller),
                      ),
                    ),
                  );
                }
                if (snapshot.connectionState == ConnectionState.done &&
                    snapshot.data == false) {
                  return _failedView();
                }
                return _preparingView();
              },
            ),
          ),
          if (_fallbackNotice != null)
            Positioned(
              top: 16,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  key: const Key('gallery-video-fallback-notice'),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: CupertinoColors.black.withValues(alpha: .7),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(_fallbackNotice!,
                      style: const TextStyle(
                          fontSize: 13, color: CupertinoColors.white)),
                ),
              ),
            ),
          Positioned(
            top: 12,
            left: 12,
            child: CupertinoButton(
              key: const Key('gallery-video-back'),
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
              key: const Key('gallery-video-select'),
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

  /// 准备阶段：缩略图底 + 进度百分比（转码事件驱动；无事件时活动指示器）。
  Widget _preparingView() => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (widget.thumbnailBytes.isNotEmpty)
            AspectRatio(
              aspectRatio: 4 / 3,
              child: Image.memory(widget.thumbnailBytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true),
            )
          else
            const Icon(CupertinoIcons.videocam,
                size: 48, color: CupertinoColors.systemGrey),
          const SizedBox(height: 16),
          Text(_prepareLabel,
              style: const TextStyle(
                  fontSize: 13, color: CupertinoColors.systemGrey)),
          const SizedBox(height: 10),
          SizedBox(
            width: 180,
            child: _prepareProgress == null
                ? const CupertinoActivityIndicator()
                : ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: SizedBox(
                      height: 6,
                      child: Stack(children: [
                        ColoredBox(
                            color: CupertinoColors.systemGrey
                                .withValues(alpha: .35)),
                        FractionallySizedBox(
                          widthFactor: _prepareProgress!
                              .clamp(0.02, 1.0)
                              .toDouble(),
                          child: const ColoredBox(
                              color: WeChatColors.brandPrimary),
                        ),
                      ]),
                    ),
                  ),
          ),
          if (_prepareProgress != null) ...[
            const SizedBox(height: 6),
            Text('${(_prepareProgress! * 100).round()}%',
                style: const TextStyle(
                    fontSize: 12, color: CupertinoColors.systemGrey)),
          ],
        ],
      );

  /// 失败视图：压缩与解码均失败时仍可重试或仅选择发送。
  Widget _failedView() => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (widget.thumbnailBytes.isNotEmpty)
            Image.memory(widget.thumbnailBytes, fit: BoxFit.contain)
          else
            const Icon(CupertinoIcons.videocam,
                size: 48, color: CupertinoColors.systemGrey),
          const SizedBox(height: 12),
          Text(
            '视频准备失败（${_format(widget.duration)}），可重试；'
            '重试失败仍可选择发送',
            style: TextStyle(
                fontSize: 13, color: CupertinoColors.systemGrey),
          ),
          const SizedBox(height: 10),
          CupertinoButton(
            key: const Key('gallery-video-retry'),
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            color: WeChatColors.brandPrimary,
            borderRadius: BorderRadius.circular(16),
            onPressed: _retry,
            child: const Text('重试',
                style: TextStyle(
                    fontSize: 14, color: CupertinoColors.white)),
          ),
        ],
      );
}
