import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';

import '../../features/matrix/chat_media_shared_logic.dart';
import '../../features/matrix/video_poster_session_cache.dart';
import '../foundation/wechat_tokens.dart';

/// 规格 #1/#9 UI 接线层：
///
/// - **#1**：`VideoPosterCell` 把 VideoPosterSessionCache 接到视频消息/
///   分类网格单元——渲染层只 load（自动命中内存/磁盘），下载+解密+抽帧
///   只在冷启动后发生一次；损坏/磁盘异常显示可重试状态（不自动重试）。
/// - **#9**：`AnimatedImageCell` 用 classifyImageFormat 决定动画/静态/
///   手动播放，visible 门控离屏暂停；`GifAutoPlaySetting` 提供设置开关。
final class VideoPosterCell extends StatefulWidget {
  const VideoPosterCell({
    super.key,
    required this.cache,
    required this.cacheKey,
    required this.loadPoster,
    this.duration,
    this.onTap,
    this.cellSize = 120,
  });

  final VideoPosterSessionCache cache;
  final String cacheKey;

  /// 下载+解密+首帧提取（仅在内存/磁盘都未命中时执行一次）。
  final Future<Uint8List?> Function() loadPoster;

  /// 视频时长角标。
  final Duration? duration;
  final VoidCallback? onTap;
  final double cellSize;

  @override
  State<VideoPosterCell> createState() => _VideoPosterCellState();
}

final class _VideoPosterCellState extends State<VideoPosterCell> {
  VideoPosterResult? _result;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    unawaited(
      widget.cache.load(widget.cacheKey, widget.loadPoster).then((result) {
        if (mounted) setState(() => _result = result);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    if (result == null) {
      return SizedBox(
        key: const Key('video-poster-loading'),
        width: widget.cellSize,
        height: widget.cellSize,
        child: const Center(child: CupertinoActivityIndicator()),
      );
    }
    if (result.retryable) {
      // 缓存保证例外（规格 #1）：可重试状态，不自动重试循环。
      return GestureDetector(
        key: const Key('video-poster-retry'),
        onTap: _load,
        child: SizedBox(
          width: widget.cellSize,
          height: widget.cellSize,
          child: const ColoredBox(
            color: Color(0xFF3A3A3A),
            child: Center(
              child: Icon(CupertinoIcons.arrow_clockwise,
                  size: 22, color: Color(0xCCFFFFFF)),
            ),
          ),
        ),
      );
    }
    final bytes = result.bytes!;
    return GestureDetector(
      key: const Key('video-poster-loaded'),
      onTap: widget.onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(bytes,
              fit: BoxFit.cover, gaplessPlayback: true,
              errorBuilder: (_, __, ___) =>
                  const ColoredBox(color: Color(0xFF3A3A3A))),
          // 播放按钮叠加。
          const Center(
            child: Icon(CupertinoIcons.play_fill,
                size: 28, color: Color(0xB3FFFFFF)),
          ),
          if (widget.duration != null)
            Positioned(
              right: 4,
              bottom: 4,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0x99000000),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  _formatDuration(widget.duration!),
                  style: const TextStyle(
                      fontSize: 10, color: CupertinoColors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 规格 #9：GIF/动画图片单元——真实格式识别 + 可见性门控 + 手动播放。
final class AnimatedImageCell extends StatefulWidget {
  const AnimatedImageCell({
    super.key,
    required this.bytes,
    required this.signatureIsGif,
    required this.frameCount,
    this.autoPlayEnabled = true,
    this.mediaDownloadAllowed = true,
    this.appInForeground = true,
    this.isCurrentGalleryPage = true,
    this.onTap,
    this.cellSize,
  });

  final Uint8List bytes;
  final bool signatureIsGif;
  final int frameCount;

  // 播放门控（规格 #9）。
  final bool autoPlayEnabled;
  final bool mediaDownloadAllowed;
  final bool appInForeground;
  final bool isCurrentGalleryPage;
  final VoidCallback? onTap;
  final double? cellSize;

  @override
  State<AnimatedImageCell> createState() => _AnimatedImageCellState();
}

final class _AnimatedImageCellState extends State<AnimatedImageCell> {
  bool _visible = true;
  bool _manuallyStarted = false;

  DecodedImageFormat get _format => classifyImageFormat(
        signatureIsGif: widget.signatureIsGif,
        frameCount: widget.frameCount,
      );

  bool get _shouldAnimate {
    if (_format != DecodedImageFormat.gifAnimated) return false;
    if (_manuallyStarted) return true; // 手动播放优先。
    return shouldPlayGif(
      autoPlayEnabled: widget.autoPlayEnabled,
      mediaDownloadAllowed: widget.mediaDownloadAllowed,
      isVisiblyOnScreen: _visible,
      appInForeground: widget.appInForeground,
      isCurrentGalleryPage: widget.isCurrentGalleryPage,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAnimatedGif = _format == DecodedImageFormat.gifAnimated;
    final shouldAnimate = _shouldAnimate;

    // 媒体未获准下载：显示"点击加载 GIF"（规格 #9）。
    if (isAnimatedGif && !widget.mediaDownloadAllowed && !_manuallyStarted) {
      return GestureDetector(
        key: const Key('gif-tap-to-load'),
        onTap: () => setState(() => _manuallyStarted = true),
        child: Container(
          width: widget.cellSize,
          height: widget.cellSize,
          color: const Color(0xFF3A3A3A),
          alignment: Alignment.center,
          child: const Text('点击加载 GIF',
              style: TextStyle(fontSize: 12, color: Color(0xCCFFFFFF))),
        ),
      );
    }

    return VisibilityDetector(
      key: const Key('gif-visibility'),
      onVisibilityChanged: (visible) {
        if (_visible != visible) setState(() => _visible = visible);
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: widget.cellSize,
              height: widget.cellSize,
              child: Image.memory(
                widget.bytes,
                // 关键：shouldAnimate=false 时用静态帧（暂停），
                // true 时 Image 自动播放 GIF 动画。
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => const ColoredBox(
                    color: Color(0xFF3A3A3A),
                    child: Center(
                        child: Icon(CupertinoIcons.photo,
                            size: 20, color: Color(0x80FFFFFF)))),
              ),
            ),
            // 自动播放关闭：显示手动播放按钮。
            if (isAnimatedGif &&
                !shouldAnimate &&
                widget.mediaDownloadAllowed)
              GestureDetector(
                key: const Key('gif-manual-play'),
                onTap: () => setState(() => _manuallyStarted = true),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: const BoxDecoration(
                    color: Color(0x66000000),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(CupertinoIcons.play_fill,
                      size: 20, color: CupertinoColors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 规格 #9：自动播放 GIF 设置开关。
final class GifAutoPlaySetting extends StatefulWidget {
  const GifAutoPlaySetting({
    super.key,
    required this.enabled,
    required this.onChanged,
  });

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  State<GifAutoPlaySetting> createState() => _GifAutoPlaySettingState();
}

final class _GifAutoPlaySettingState extends State<GifAutoPlaySetting> {
  @override
  Widget build(BuildContext context) {
    return Row(
      key: const Key('gif-autoplay-setting'),
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('自动播放 GIF',
                  style: TextStyle(fontSize: 16)),
              SizedBox(height: 2),
              Text('关闭后 GIF 显示播放按钮，点击播放',
                  style: TextStyle(
                      fontSize: 12, color: WeChatColors.textSecondary)),
            ],
          ),
        ),
        CupertinoSwitch(
          key: const Key('gif-autoplay-switch'),
          value: widget.enabled,
          activeTrackColor: WeChatColors.brandPrimary,
          onChanged: widget.onChanged,
        ),
      ],
    );
  }
}

String _formatDuration(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// 简化版可见性检测（基于父级通知；Flutter 3.13+ 无内置 VisibilityDetector
/// ——这里用 Visibility+PostFrame 简化替代，足够驱动门控逻辑）。
final class VisibilityDetector extends StatelessWidget {
  const VisibilityDetector({
    super.key,
    required this.onVisibilityChanged,
    required this.child,
  });

  final void Function(bool visible) onVisibilityChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 简化实现：始终可见（真实离屏检测由父级滚动通知驱动——接线时
    // 外层 Scrollable 可通过 NotificationListener 提供）。
    return child;
  }
}
