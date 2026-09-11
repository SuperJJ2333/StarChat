import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:photo_manager/photo_manager.dart';
import 'encrypted_media_view.dart';
import '../../core/gallery_save_access.dart';
import '../../core/screen_on_lease_coordinator.dart';

import '../foundation/wechat_tokens.dart';
import 'video_playback_lease_coordinator.dart';

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

  static final _screenOnDemand = ScreenOnDemand(screenOnLeaseCoordinator);
  static final _wakelockCoordinator =
      VideoPlaybackLeaseCoordinator(_screenOnDemand.setEnabled);

  @visibleForTesting
  static Future<void> debugWakelockSettled() => _wakelockCoordinator.settled;

  @override
  State<VideoViewerPage> createState() => _VideoViewerPageState();
}

final class _VideoViewerPageState extends State<VideoViewerPage>
    with WidgetsBindingObserver {
  static _VideoViewerPageState? _activePage;
  static var _activationIntent = 0;
  VideoPlayerController? _controller;
  VideoPlayerController? _pendingController;
  Future<bool>? _initFuture;
  Timer? _uiTicker;
  File? _videoFile;
  bool _saving = false;
  bool _forwarding = false;
  String? _hint;
  var _generation = 0;
  var _activationRevision = 0;
  var _manualPaused = false;
  var _resumeInFlight = false;
  var _resumeRequest = 0;
  var _appActive = true;
  var _routeCurrent = true;
  int? _lease;

  VideoPlaybackLeaseCoordinator get _leaseCoordinator =>
      VideoViewerPage._wakelockCoordinator;

  /// 加载/初始化失败后可重试（弱网大文件场景）。
  bool loadFailed = false;

  Future<bool> _initialize() async {
    final generation = ++_generation;
    loadFailed = false;
    VideoPlayerController? pendingController;
    try {
      final videoFile =
          await widget.loadFile().timeout(const Duration(seconds: 30));
      if (!mounted || generation != _generation) return false;
      final controller = widget.controllerFactory?.call(videoFile) ??
          VideoPlayerController.file(videoFile);
      pendingController = controller;
      _pendingController = controller;
      await controller.initialize().timeout(const Duration(seconds: 30));
      if (!mounted || generation != _generation) {
        await controller.dispose();
        return false;
      }
      await _activate(controller, generation);
      if (!mounted || generation != _generation) {
        await controller.dispose();
        return false;
      }
      if (mounted) {
        setState(() {
          _controller = controller;
          if (identical(_pendingController, controller)) {
            _pendingController = null;
          }
          _videoFile = videoFile;
          loadFailed = false;
        });
      }
      return true;
    } catch (_) {
      if (identical(_pendingController, pendingController)) {
        _pendingController = null;
      }
      await pendingController?.dispose();
      if (mounted && generation == _generation) {
        setState(() => loadFailed = true);
      }
      return false;
    }
  }

  Future<void> _activate(
      VideoPlayerController controller, int generation) async {
    if (!mounted ||
        generation != _generation ||
        !_appActive ||
        !_routeCurrent ||
        _manualPaused) {
      return;
    }
    final globalIntent = ++_activationIntent;
    final localIntent = ++_activationRevision;
    final previous = _activePage;
    if (previous != null && !identical(previous, this)) {
      await previous._pauseForLifecycle();
    }
    if (!mounted ||
        generation != _generation ||
        globalIntent != _activationIntent ||
        localIntent != _activationRevision ||
        !_appActive ||
        !_routeCurrent ||
        _manualPaused) {
      return;
    }
    _activePage = this;
    final lease = _leaseCoordinator.acquire();
    _lease = lease;
    try {
      await controller.play();
    } catch (_) {
      _leaseCoordinator.revoke(lease);
      if (_lease == lease) _lease = null;
      if (identical(_activePage, this)) _activePage = null;
      _uiTicker?.cancel();
      rethrow;
    }
    if (!mounted ||
        generation != _generation ||
        globalIntent != _activationIntent ||
        localIntent != _activationRevision ||
        !_appActive ||
        !_routeCurrent ||
        _manualPaused ||
        _leaseCoordinator.current != lease) {
      await controller.pause();
      _leaseCoordinator.revoke(lease);
      if (_lease == lease) _lease = null;
      return;
    }
    _startTicker();
  }

  void _startTicker() {
    _uiTicker?.cancel();
    _uiTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      if (_controller?.value.isPlaying == true) {
        setState(() {});
      } else {
        _uiTicker?.cancel();
        unawaited(_pauseForLifecycle());
      }
    });
  }

  Future<void> _pauseForLifecycle() async {
    // Invalidate this page's activation without cancelling a newer page.
    _activationRevision++;
    _uiTicker?.cancel();
    final lease = _lease;
    _lease = null;
    if (lease != null) {
      _leaseCoordinator.revoke(lease);
    }
    if (identical(_activePage, this)) _activePage = null;
    final controller = _controller ?? _pendingController;
    try {
      await controller?.pause();
    } catch (_) {
      // A controller can be disposed by a newer retry while this pause awaits.
    }
  }

  /// 「重试」：重新下载解密并初始化播放器。
  void _retry() {
    _generation++;
    unawaited(_pauseForLifecycle());
    _controller?.dispose();
    _controller = null;
    setState(() {
      _initFuture = _initialize();
    });
  }

  @override
  void initState() {
    super.initState();
    _appActive =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _initFuture = _initialize();
  }

  Future<void> _togglePlay() async {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      _manualPaused = true;
      await _pauseForLifecycle();
    } else {
      _manualPaused = false;
      await _resume(controller);
    }
    if (mounted) setState(() {});
  }

  Future<void> _resume(VideoPlayerController controller) async {
    _resumeRequest++;
    if (_resumeInFlight) return;
    _resumeInFlight = true;
    try {
      while (true) {
        final request = _resumeRequest;
        try {
          await _activate(controller, _generation);
        } catch (_) {
          if (mounted) setState(() => _hint = '视频播放失败，请重试');
          return;
        }
        if (request == _resumeRequest ||
            !mounted ||
            !_appActive ||
            !_routeCurrent ||
            _manualPaused ||
            controller.value.isPlaying) {
          return;
        }
      }
    } finally {
      _resumeInFlight = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    if (!_appActive) unawaited(_pauseForLifecycle());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (_routeCurrent == current) return;
    _routeCurrent = current;
    if (!current) {
      unawaited(_pauseForLifecycle());
    } else if (!_manualPaused) {
      final controller = _controller;
      if (controller != null) unawaited(_resume(controller));
    }
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
      await _pauseForLifecycle();
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
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_pauseForLifecycle());
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
