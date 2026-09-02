import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../foundation/wechat_tokens.dart';

/// 视频消息媒体卡（微信式，无气泡）：封面海报帧 + 播放按钮 + 时长角标。
/// 海报帧来自发送端附带的加密缩略图（[posterLoader]，≤480px 小图），
/// 无缩略图（旧消息/生成失败）时回退 videocam 占位底。
/// 点击触发 [onOpen] 进入全屏播放。
final class VideoMessageCard extends StatelessWidget {
  const VideoMessageCard({
    super.key,
    required this.duration,
    required this.onOpen,
    this.posterLoader,
  });

  final Duration? duration;
  final VoidCallback onOpen;

  /// 加载封面帧字节（发送端压缩演绎版）；null/失败回退占位底。
  final Future<Uint8List?> Function()? posterLoader;

  String get _durationText {
    final total = duration?.inSeconds ?? 0;
    final minutes = total ~/ 60;
    final seconds = (total % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onOpen,
        child: SizedBox(
          width: 200,
          height: 150,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(WeChatRadius.bubble),
            child: ColoredBox(
              color: CupertinoColors.black,
              child: Stack(fit: StackFit.expand, children: [
                if (posterLoader == null)
                  const Center(
                    child: Icon(CupertinoIcons.videocam_fill,
                        size: 34, color: CupertinoColors.systemGrey),
                  )
                else
                  FutureBuilder<Uint8List?>(
                    future: posterLoader!(),
                    builder: (context, snapshot) {
                      final poster = snapshot.data;
                      if (poster != null && poster.isNotEmpty) {
                        return Image.memory(poster,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            errorBuilder: (_, __, ___) =>
                                const Center(
                                  child: Icon(CupertinoIcons.videocam_fill,
                                      size: 34,
                                      color: CupertinoColors.systemGrey),
                                ));
                      }
                      if (snapshot.connectionState !=
                          ConnectionState.done) {
                        return const Center(
                            child: CupertinoActivityIndicator());
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
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 2),
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

/// 全屏视频播放页：加载解密字节 → 临时文件 → 播放器；
/// 播放/暂停、进度与时长、屏幕常亮；退出即停止。
final class VideoViewerPage extends StatefulWidget {
  const VideoViewerPage({
    super.key,
    required this.loadBytes,
    this.initialDuration,
  });

  final Future<Uint8List> Function() loadBytes;
  final Duration? initialDuration;

  @override
  State<VideoViewerPage> createState() => _VideoViewerPageState();
}

final class _VideoViewerPageState extends State<VideoViewerPage> {
  VideoPlayerController? _controller;
  Future<bool>? _initFuture;
  Timer? _uiTicker;

  /// 加载/初始化失败后可重试（弱网大文件场景）。
  bool loadFailed = false;

  Future<bool> _initialize() async {
    File? temp;
    loadFailed = false;
    try {
      final bytes = await widget.loadBytes();
      temp = File(
          '${Directory.systemTemp.path}/changliao-video-'
          '${DateTime.now().microsecondsSinceEpoch}.mp4');
      await temp.writeAsBytes(bytes, flush: true);
      final controller = VideoPlayerController.file(temp);
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return false;
      }
      unawaited(WakelockPlus.enable());
      await controller.play();
      if (mounted) {
        setState(() {
          _controller = controller;
          loadFailed = false;
        });
      }
      _uiTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted) setState(() {});
      });
      return true;
    } catch (_) {
      if (mounted) {
        setState(() => loadFailed = true);
      }
      return false;
    }
  }

  /// 「重试」：重新下载解密并初始化播放器。
  void _retry() {
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

  String _format(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:${seconds.padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _uiTicker?.cancel();
    unawaited(WakelockPlus.disable());
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
                                return const CupertinoActivityIndicator();
                              }
                              if (snapshot.data == true) {
                                return const SizedBox.shrink();
                              }
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    loadFailed
                                        ? '视频加载失败，请检查网络后重试'
                                        : '视频加载失败',
                                    style: const TextStyle(
                                        color:
                                            CupertinoColors.systemGrey),
                                  ),
                                  const SizedBox(height: 12),
                                  CupertinoButton(
                                    key: const Key(
                                        'video-viewer-retry'),
                                    color: CupertinoColors.systemGrey
                                        .withValues(alpha: .35),
                                    borderRadius:
                                        BorderRadius.circular(16),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 20, vertical: 6),
                                    onPressed: _retry,
                                    child: const Text('重试',
                                        style: TextStyle(
                                            fontSize: 14,
                                            color: CupertinoColors
                                                .white)),
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
                const Expanded(
                  child: Text('加密视频',
                      textAlign: TextAlign.end,
                      style: TextStyle(
                          fontSize: 12,
                          color: CupertinoColors.systemGrey)),
                ),
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
