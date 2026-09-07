import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:photo_manager/photo_manager.dart';
import 'encrypted_media_view.dart';
import '../../core/gallery_save_access.dart';

import '../foundation/wechat_tokens.dart';

/// 视频消息媒体卡（微信式，无气泡）：封面海报帧 + 播放按钮 + 时长角标。
/// 海报帧来自发送端附带的加密缩略图（[posterLoader]，≤480px 小图），
/// 无缩略图（旧消息/生成失败）时回退 videocam 占位底。
/// 点击触发 [onOpen] 进入全屏播放。
final class VideoMessageCard extends StatefulWidget {
  const VideoMessageCard({
    super.key,
    required this.duration,
    required this.onOpen,
    this.posterLoader,
    this.posterIdentity,
  });

  final Duration? duration;
  final VoidCallback onOpen;

  /// 加载封面帧字节（发送端压缩演绎版）；null/失败回退占位底。
  final Future<Uint8List?> Function()? posterLoader;

  /// Changes only when the source event changes, not on every parent build.
  final Object? posterIdentity;

  @override
  State<VideoMessageCard> createState() => _VideoMessageCardState();
}

final class _VideoMessageCardState extends State<VideoMessageCard> {
  Future<Uint8List?>? _poster;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final loader = widget.posterLoader;
    _poster = loader == null ? null : Future<Uint8List?>.sync(loader);
  }

  @override
  void didUpdateWidget(covariant VideoMessageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.posterIdentity != widget.posterIdentity ||
        (oldWidget.posterLoader == null) != (widget.posterLoader == null)) {
      _load();
    }
  }

  String get _durationText {
    final duration = widget.duration;
    if (duration == null || duration <= Duration.zero) return '--:--';
    final total = duration.inSeconds;
    final minutes = total ~/ 60;
    final seconds = (total % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: widget.onOpen,
        child: SizedBox(
          width: 200,
          height: 150,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(WeChatRadius.bubble),
            child: ColoredBox(
              color: CupertinoColors.black,
              child: Stack(fit: StackFit.expand, children: [
                if (_poster == null)
                  const Center(
                    child: Icon(CupertinoIcons.videocam_fill,
                        size: 34, color: CupertinoColors.systemGrey),
                  )
                else
                  FutureBuilder<Uint8List?>(
                    future: _poster,
                    builder: (context, snapshot) {
                      final poster = snapshot.data;
                      if (poster != null && poster.isNotEmpty) {
                        return Image.memory(poster,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            errorBuilder: (_, __, ___) => const Center(
                                  child: Icon(CupertinoIcons.videocam_fill,
                                      size: 34,
                                      color: CupertinoColors.systemGrey),
                                ));
                      }
                      return const Center(
                        child: Icon(CupertinoIcons.videocam_fill,
                            size: 34, color: CupertinoColors.systemGrey),
                      );
                    },
                  ),
                Center(
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: CupertinoColors.black.withValues(alpha: .45),
                      border: Border.all(
                        color: CupertinoColors.white,
                        width: 1.5,
                      ),
                    ),
                    child: const Icon(CupertinoIcons.play_arrow_solid,
                        size: 24, color: CupertinoColors.white),
                  ),
                ),
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: CupertinoColors.black.withValues(alpha: .55),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(_durationText,
                        style: const TextStyle(
                            fontSize: 10, color: CupertinoColors.white)),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
}

/// 全屏视频播放页：播放文件由外部解析（磁盘缓存优先，见
/// resolveCachedVideoFile）；播放/暂停、进度与时长、屏幕常亮；退出即停止。
final class VideoViewerPage extends StatefulWidget {
  const VideoViewerPage({
    super.key,
    required this.loadFile,
    this.initialDuration,
    this.onForward,
    this.controllerFactory,
  });

  final Future<File> Function() loadFile;
  final Duration? initialDuration;
  final Future<void> Function()? onForward;
  final VideoPlayerController Function(File file)? controllerFactory;

  @override
  State<VideoViewerPage> createState() => _VideoViewerPageState();
}

final class _VideoViewerPageState extends State<VideoViewerPage> {
  VideoPlayerController? _controller;
  Future<bool>? _initFuture;
  Timer? _uiTicker;
  File? _videoFile;
  bool _saving = false;
  bool _forwarding = false;
  String? _hint;

  /// 加载/初始化失败后可重试（弱网大文件场景）。
  bool loadFailed = false;

  Future<bool> _initialize() async {
    loadFailed = false;
    VideoPlayerController? pendingController;
    try {
      final videoFile =
          await widget.loadFile().timeout(const Duration(seconds: 30));
      if (!mounted) return false;
      final controller = widget.controllerFactory?.call(videoFile) ??
          VideoPlayerController.file(videoFile);
      pendingController = controller;
      await controller.initialize().timeout(const Duration(seconds: 30));
      if (!mounted) {
        await controller.dispose();
        return false;
      }
      await controller.play();
      if (!mounted) {
        await controller.dispose();
        return false;
      }
      unawaited(WakelockPlus.enable().catchError((Object _) {}));
      if (mounted) {
        setState(() {
          _controller = controller;
          _videoFile = videoFile;
          loadFailed = false;
        });
      }
      _uiTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted) setState(() {});
      });
      return true;
    } catch (_) {
      await pendingController?.dispose();
      if (mounted) {
        setState(() => loadFailed = true);
      }
      return false;
    }
  }

  /// 「重试」：重新下载解密并初始化播放器。
  void _retry() {
    _uiTicker?.cancel();
    _controller?.dispose();
    _controller = null;
    setState(() {
      _initFuture = _initialize();
    });
  }

  @override
  void initState() {
    super.initState();
    _initFuture = _initialize();
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

  Future<void> _download() async {
    if (_saving || _videoFile == null) return;
    setState(() => _saving = true);
    try {
      await ensureGallerySaveAccess();
      final asset = await PhotoManager.editor.saveVideo(_videoFile!,
          title: 'ChatFlow-${DateTime.now().millisecondsSinceEpoch}.mp4');
      if (mounted) {
        setState(() => _hint = asset.id.isNotEmpty ? '已保存到相册' : '保存失败，请稍后重试');
      }
    } catch (error) {
      if (mounted) setState(() => _hint = gallerySaveErrorMessage(error));
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _forward() async {
    if (_forwarding) return;
    setState(() => _forwarding = true);
    try {
      await _controller?.pause();
      await widget.onForward?.call();
    } catch (_) {
      if (mounted) setState(() => _hint = '转发失败，请重试');
    } finally {
      if (mounted) setState(() => _forwarding = false);
    }
  }

  Future<void> _chooseSpeed() async {
    final speed = await showCupertinoModalPopup<double>(
        context: context,
        builder: (sheet) => CupertinoActionSheet(
            title: const Text('播放速度'),
            actions: [
              for (final rate in [0.5, 1.0, 1.5, 2.0])
                CupertinoActionSheetAction(
                    onPressed: () => Navigator.pop(sheet, rate),
                    child: Text('$rate×'))
            ],
            cancelButton: CupertinoActionSheetAction(
                onPressed: () => Navigator.pop(sheet),
                child: const Text('取消'))));
    if (speed == null || !mounted) return;
    try {
      await _controller?.setPlaybackSpeed(speed);
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _hint = '该视频暂不支持此倍速');
    }
  }

  String _format(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:${seconds.padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _uiTicker?.cancel();
    unawaited(WakelockPlus.disable().catchError((Object _) {}));
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;
    final position = controller?.value.position;
    final total = controller?.value.duration ?? widget.initialDuration;
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.black,
      child: SafeArea(
        child: Stack(children: [
          Positioned.fill(
            child: ready
                ? GestureDetector(
                    onTap: _togglePlay,
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: controller.value.aspectRatio,
                        child: VideoPlayer(controller),
                      ),
                    ),
                  )
                : Center(
                    child: _initFuture == null
                        ? const CupertinoActivityIndicator()
                        : FutureBuilder<bool>(
                            future: _initFuture,
                            builder: (context, snapshot) {
                              if (snapshot.connectionState !=
                                  ConnectionState.done) {
                                return const Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CupertinoActivityIndicator(),
                                    SizedBox(height: 12),
                                    Text('正在加载视频…',
                                        style: TextStyle(
                                            color: CupertinoColors.systemGrey)),
                                  ],
                                );
                              }
                              if (snapshot.data == true) {
                                return const SizedBox.shrink();
                              }
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    loadFailed ? '视频加载失败，请检查网络后重试' : '视频加载失败',
                                    style: const TextStyle(
                                        color: CupertinoColors.systemGrey),
                                  ),
                                  const SizedBox(height: 12),
                                  CupertinoButton(
                                    key: const Key('video-viewer-retry'),
                                    color: CupertinoColors.systemGrey
                                        .withValues(alpha: .35),
                                    borderRadius: BorderRadius.circular(16),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 20, vertical: 6),
                                    onPressed: _retry,
                                    child: const Text('重试',
                                        style: TextStyle(
                                            fontSize: 14,
                                            color: CupertinoColors.white)),
                                  ),
                                ],
                              );
                            },
                          ),
                  ),
          ),
          Positioned(
            top: 12,
            left: 12,
            child: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => Navigator.pop(context),
              child: const Icon(CupertinoIcons.chevron_back,
                  size: 22, color: CupertinoColors.white),
            ),
          ),
          Positioned(
              right: 16,
              bottom: 110,
              child: Column(children: [
                ViewerRoundAction(
                    key: const Key('video-viewer-download'),
                    icon: CupertinoIcons.cloud_download,
                    label: _saving ? '保存中' : '下载',
                    onPressed: ready && !_saving ? _download : null),
                const SizedBox(height: 14),
                if (widget.onForward != null)
                  ViewerRoundAction(
                      key: const Key('video-viewer-forward'),
                      icon: CupertinoIcons.paperplane,
                      label: '转发',
                      onPressed: _forwarding ? null : _forward),
              ])),
          if (_hint != null)
            Positioned(
                left: 0,
                right: 0,
                bottom: 96,
                child: ViewerStatusHint(message: _hint!)),
          if (ready)
            Positioned(
                left: 12,
                right: 12,
                bottom: 62,
                child: CupertinoSlider(
                  key: const Key('video-viewer-progress'),
                  value: controller.value.position.inMilliseconds
                      .toDouble()
                      .clamp(
                          0,
                          controller.value.duration.inMilliseconds
                              .toDouble()
                              .clamp(1, double.infinity)),
                  max: controller.value.duration.inMilliseconds
                      .toDouble()
                      .clamp(1, double.infinity),
                  onChanged: (value) =>
                      controller.seekTo(Duration(milliseconds: value.round())),
                )),
          if (ready)
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: Row(children: [
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  onPressed: _togglePlay,
                  child: Icon(
                    controller.value.isPlaying
                        ? CupertinoIcons.pause_circle
                        : CupertinoIcons.play_circle,
                    size: 30,
                    color: CupertinoColors.white,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _format(position ?? Duration.zero),
                  style: const TextStyle(
                      fontSize: 12, color: CupertinoColors.white),
                ),
                const SizedBox(width: 8),
                const Spacer(),
                CupertinoButton(
                    key: const Key('video-viewer-speed'),
                    padding: EdgeInsets.zero,
                    onPressed: _chooseSpeed,
                    child: Text('${controller.value.playbackSpeed}×',
                        style: const TextStyle(
                            fontSize: 14, color: CupertinoColors.white))),
                if (total != null) ...[
                  const SizedBox(width: 8),
                  Text(_format(total),
                      style: const TextStyle(
                          fontSize: 12, color: CupertinoColors.white)),
                ],
              ]),
            ),
        ]),
      ),
    );
  }
}
