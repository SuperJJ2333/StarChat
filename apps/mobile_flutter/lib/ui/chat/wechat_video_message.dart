import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:photo_manager/photo_manager.dart';
import 'encrypted_media_view.dart';
import '../../core/gallery_save_access.dart';

import '../foundation/wechat_tokens.dart';
import '../components/network_status_capsule.dart';
import 'video_playback_lease_coordinator.dart';
import 'video_playback_arbiter.dart';
import 'shared_video_playback.dart';
import 'media_visibility.dart';

/// 视频封面加载窗口：可见区域上下各外扩 5 行（约 ±790pt）。
///
/// 只有「可见 + 即将进入」的行才会请求封面；列表首屏构建/快速滚动时
/// 离屏很远的行不会触发封面生成（Phase 1：视频列表首屏不触发全部处理）。
const int kVideoPosterWarmRows = 5;

/// 单行视频消息的标称高度（卡片 150 + 行间距），用于把「±5 行」换算成像素。
const double kVideoPosterRowExtent = 158;

/// 封面加载的前瞻像素（= ±5 行）。
const double kVideoPosterWarmExtent =
    kVideoPosterWarmRows * kVideoPosterRowExtent;

/// 视频消息媒体卡（微信式，无气泡）：封面海报帧 + 播放按钮 + 时长角标。
/// 海报帧来自发送端附带的加密缩略图（[posterLoader]，≤480px 小图），
/// 无缩略图（旧消息/生成失败）时回退 videocam 占位底。
/// 点击触发 [onOpen] 进入全屏播放。
///
/// **可见性门控（Phase 1）**：`posterLoader` 只在卡片进入「可见区域
/// ±[kVideoPosterWarmRows] 行」时才被调用——进入列表/快速滚动不会
/// 触发全部视频的封面处理。
final class VideoMessageCard extends StatefulWidget {
  const VideoMessageCard({
    super.key,
    required this.duration,
    required this.onOpen,
    this.posterLoader,
    this.posterIdentity,
    this.posterRevision = 0,
  });

  final Duration? duration;
  final VoidCallback onOpen;

  /// 加载封面帧字节（发送端压缩演绎版）；null/失败回退占位底。
  final Future<Uint8List?> Function()? posterLoader;

  /// Changes only when the source event changes, not on every parent build.
  final Object? posterIdentity;

  /// 封面补生成信号：视频播放完成（本地已有文件）后由宿主 +1，
  /// 卡片重新解析一次封面（可能从「抽帧本地视频」拿到结果）。
  final int posterRevision;

  @override
  State<VideoMessageCard> createState() => _VideoMessageCardState();
}

final class _VideoMessageCardState extends State<VideoMessageCard> {
  Future<Uint8List?>? _poster;
  bool _posterWindowOpen = false;

  @override
  void initState() {
    super.initState();
    // 首帧不请求：等可见性窗口报告（帧后回调）再加载。
  }

  void _onWindowChanged(MediaVisibilityWindow window) {
    final open = window != MediaVisibilityWindow.hidden;
    if (open == _posterWindowOpen) return;
    if (mounted) {
      setState(() => _posterWindowOpen = open);
    } else {
      _posterWindowOpen = open;
    }
    if (open) _load();
  }

  void _load() {
    if (!_posterWindowOpen) return;
    final loader = widget.posterLoader;
    _poster = loader == null ? null : Future<Uint8List?>.sync(loader);
  }

  @override
  void didUpdateWidget(covariant VideoMessageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.posterIdentity != widget.posterIdentity ||
        oldWidget.posterRevision != widget.posterRevision ||
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
  Widget build(BuildContext context) => MediaVisibility(
        warmExtent: kVideoPosterWarmExtent,
        onChanged: (_) {},
        onWindowChanged: _onWindowChanged,
        child: GestureDetector(
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

  @visibleForTesting
  static Future<void> debugWakelockSettled() =>
      SharedVideoPlayback.wakelockCoordinator.settled;
  @visibleForTesting
  static ({bool current, bool pending, bool retry}) get debugArbiterState => (
        current: SharedVideoPlayback.arbiter.debugHasCurrent,
        pending: SharedVideoPlayback.arbiter.debugHasPendingBarrier,
        retry: SharedVideoPlayback.arbiter.debugHasRetryPause
      );

  @override
  State<VideoViewerPage> createState() => _VideoViewerPageState();
}

final class _VideoViewerPageState extends State<VideoViewerPage>
    with WidgetsBindingObserver {
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
  VideoPlaybackReservation? _activationReservation;
  Future<void>? _pauseInFlight;
  late final Future<void> Function() _ownerPause = _pauseForLifecycle;
  var _controllerDisposeConfirmed = false;

  VideoPlaybackLeaseCoordinator get _leaseCoordinator =>
      SharedVideoPlayback.wakelockCoordinator;

  /// 加载/初始化失败后可重试（弱网大文件场景）。
  bool loadFailed = false;

  /// 进度条拖动中：拖动期间 ticker 不再回写位置（低端机掉帧时
  /// 回写会覆盖拖动值，表现为进度条跳动/拉不动），松手后统一 seek。
  bool _seeking = false;
  double? _seekPreviewMs;

  Future<bool> _initialize() async {
    final generation = ++_generation;
    loadFailed = false;
    VideoPlayerController? pendingController;
    try {
      // 大视频弱网回下载常见 30s+；放宽到 120s，重试按钮仍在。
      final videoFile =
          await widget.loadFile().timeout(const Duration(seconds: 120));
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
    final pendingPause = _pauseInFlight;
    if (pendingPause != null) await pendingPause;
    if (!mounted ||
        generation != _generation ||
        !_appActive ||
        !_routeCurrent ||
        _manualPaused) {
      return;
    }
    final localIntent = ++_activationRevision;
    final reservation = SharedVideoPlayback.arbiter.reserve(this, _ownerPause);
    _activationReservation = reservation;
    try {
      await reservation.waitUntilReady();
    } catch (_) {
      reservation.release();
      if (identical(_activationReservation, reservation)) {
        _activationReservation = null;
      }
      rethrow;
    }
    if (!mounted ||
        generation != _generation ||
        localIntent != _activationRevision ||
        !_appActive ||
        !_routeCurrent ||
        _manualPaused ||
        !reservation.isCurrent) {
      reservation.release();
      if (identical(_activationReservation, reservation)) {
        _activationReservation = null;
      }
      return;
    }
    final lease = _leaseCoordinator.acquire();
    _lease = lease;
    try {
      await controller.play();
    } catch (_) {
      _leaseCoordinator.revoke(lease);
      if (_lease == lease) _lease = null;
      reservation.release();
      if (identical(_activationReservation, reservation)) {
        _activationReservation = null;
      }
      _uiTicker?.cancel();
      rethrow;
    }
    if (!mounted ||
        generation != _generation ||
        localIntent != _activationRevision ||
        !_appActive ||
        !_routeCurrent ||
        _manualPaused ||
        !reservation.isCurrent ||
        _leaseCoordinator.current != lease) {
      await controller.pause();
      _leaseCoordinator.revoke(lease);
      if (_lease == lease) _lease = null;
      reservation.release();
      if (identical(_activationReservation, reservation)) {
        _activationReservation = null;
      }
      return;
    }
    _startTicker();
  }

  void _startTicker() {
    _uiTicker?.cancel();
    _uiTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted || _seeking) return;
      if (_controller?.value.isPlaying == true) {
        setState(() {});
      } else {
        _uiTicker?.cancel();
        _pauseForLifecycleSafely();
      }
    });
  }

  Future<void> _pauseForLifecycle() {
    final existing = _pauseInFlight;
    if (existing != null) return existing;
    final pause = _pauseForLifecycleImpl();
    _pauseInFlight = pause;
    return pause.whenComplete(() {
      if (identical(_pauseInFlight, pause)) _pauseInFlight = null;
    });
  }

  void _pauseForLifecycleSafely() {
    unawaited(_pauseForLifecycle().catchError((_) {}));
  }

  Future<void> _pauseForLifecycleImpl() async {
    // Invalidate this page's activation without cancelling a newer page.
    _activationRevision++;
    _uiTicker?.cancel();
    final lease = _lease;
    _lease = null;
    if (lease != null) {
      _leaseCoordinator.revoke(lease);
    }
    final reservation = _activationReservation;
    final retryPause = _ownerPause;
    final controller = _controller ?? _pendingController;
    try {
      await controller?.pause();
      SharedVideoPlayback.arbiter.clearFailedPause(retryPause);
    } catch (_) {
      if (_controllerDisposeConfirmed) return;
      if (!_controllerDisposeConfirmed) {
        SharedVideoPlayback.arbiter.recordFailedPause(retryPause);
      }
      rethrow;
    } finally {
      if (identical(_activationReservation, reservation)) {
        _activationReservation = null;
      }
      reservation?.release();
    }
  }

  /// 「重试」：重新下载解密并初始化播放器。
  void _retry() {
    _generation++;
    _pauseForLifecycleSafely();
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
    if (!_appActive) _pauseForLifecycleSafely();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (_routeCurrent == current) return;
    _routeCurrent = current;
    if (!current) {
      _pauseForLifecycleSafely();
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
    _pauseForLifecycleSafely();
    final controller = _controller;
    if (controller != null) {
      unawaited(controller.dispose().then((_) {
        _controllerDisposeConfirmed = true;
        SharedVideoPlayback.arbiter.clearFailedPause(_ownerPause);
      }, onError: (Object error, StackTrace stackTrace) {
        FlutterError.reportError(FlutterErrorDetails(
            exception: error, stack: stackTrace, library: 'video_playback'));
      }));
    }
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
            top: 48,
            left: 16,
            right: 16,
            child: Center(child: WeChatNetworkStatusCapsule()),
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
                child: _VideoProgressBar(
                  key: const Key('video-viewer-progress'),
                  positionMs: controller.value.position.inMilliseconds
                      .toDouble()
                      .clamp(
                          0,
                          controller.value.duration.inMilliseconds
                              .toDouble()
                              .clamp(1, double.infinity)),
                  durationMs: controller.value.duration.inMilliseconds
                      .toDouble()
                      .clamp(1, double.infinity),
                  seeking: _seeking,
                  previewMs: _seekPreviewMs,
                  onSeekStart: () => _seeking = true,
                  onSeekUpdate: (value) {
                    _seeking = true;
                    setState(() => _seekPreviewMs = value);
                  },
                  onSeekEnd: (value) async {
                    setState(() => _seekPreviewMs = value);
                    try {
                      await controller.seekTo(
                          Duration(milliseconds: value.round()));
                    } catch (_) {
                      if (mounted) {
                        setState(() => _hint = '跳转失败，请重试');
                      }
                    } finally {
                      if (mounted) {
                        setState(() {
                          _seeking = false;
                          _seekPreviewMs = null;
                        });
                      }
                    }
                  },
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

/// 可拖动进度条：支持点击跳转与按住拖动自由跳转；
/// 拖动期间上层暂停 ticker 回写（`seeking`），松手统一 seek。
final class _VideoProgressBar extends StatelessWidget {
  const _VideoProgressBar({
    super.key,
    required this.positionMs,
    required this.durationMs,
    required this.seeking,
    required this.previewMs,
    required this.onSeekStart,
    required this.onSeekUpdate,
    required this.onSeekEnd,
  });

  final double positionMs;
  final double durationMs;
  final bool seeking;
  final double? previewMs;
  final VoidCallback onSeekStart;
  final ValueChanged<double> onSeekUpdate;
  final ValueChanged<double> onSeekEnd;

  @override
  Widget build(BuildContext context) {
    final value = (seeking ? (previewMs ?? positionMs) : positionMs)
        .clamp(0.0, durationMs);
    return SizedBox(
      height: 28,
      child: LayoutBuilder(builder: (context, constraints) {
        final trackWidth = constraints.maxWidth;
        double fractionOf(double dx) =>
            (dx.clamp(0.0, trackWidth) / trackWidth) * durationMs;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) =>
              onSeekEnd(fractionOf(details.localPosition.dx)),
          onHorizontalDragStart: (details) {
            onSeekStart();
            onSeekUpdate(fractionOf(details.localPosition.dx));
          },
          onHorizontalDragUpdate: (details) =>
              onSeekUpdate(fractionOf(details.localPosition.dx)),
          onHorizontalDragEnd: (_) =>
              onSeekEnd(previewMs ?? positionMs),
          child: CustomPaint(
            painter: _ProgressBarPainter(value / durationMs, seeking),
            size: const Size(double.infinity, 28),
          ),
        );
      }),
    );
  }
}

final class _ProgressBarPainter extends CustomPainter {
  const _ProgressBarPainter(this.fraction, this.active);

  final double fraction;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final track = Paint()
      ..color = const Color(0x66FFFFFF)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final played = Paint()
      ..color = const Color(0xFF07C160)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(0, centerY),
        Offset(size.width, centerY), track);
    final playedWidth = (size.width * fraction.clamp(0.0, 1.0));
    if (playedWidth > 0) {
      canvas.drawLine(Offset(0, centerY), Offset(playedWidth, centerY), played);
    }
    final knobPaint = Paint()
      ..color = active ? const Color(0xFFFFFFFF) : const Color(0xDDFFFFFF);
    canvas.drawCircle(Offset(playedWidth, centerY), active ? 8 : 6, knobPaint);
  }

  @override
  bool shouldRepaint(_ProgressBarPainter old) =>
      old.fraction != fraction || old.active != active;
}
