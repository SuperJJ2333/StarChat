import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:video_player/video_player.dart';

import '../../ui/components/wechat_scaffold.dart';
import '../../core/performance_trace.dart';
import '../../ui/chat/shared_video_playback.dart';
import '../../ui/chat/video_playback_arbiter.dart';
import '../../ui/chat/video_playback_lease_coordinator.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'device_gallery_source.dart';

/// 相册视频预览页：点击图片页中的视频条目进入。
/// - 优先借用相册原片播放；不可用或解码失败才生成独立压缩产物；
///   退出或失败只释放派生产物，发送仍独立执行原有压缩策略；
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
    this.loadOriginalFile,
    this.loadTracedRendition,
    this.traceFactory,
    this.controllerFactory,
    this.viewerOnly = false,
  });

  /// 解析并转移压缩产物所有权；页面负责释放。
  final Future<VideoRendition> Function() loadRendition;
  final Future<File?> Function()? loadOriginalFile;
  final Future<VideoRendition> Function(
          PerformanceTrace? trace, void Function(double)? onProgress)?
      loadTracedRendition;
  final PerformanceTrace Function()? traceFactory;
  final Uint8List thumbnailBytes;
  final Duration? duration;
  final bool selected;
  final VoidCallback onToggle;
  final bool viewerOnly;
  final VideoPlayerController Function(File file)? controllerFactory;

  @override
  State<GalleryVideoPreviewPage> createState() =>
      _GalleryVideoPreviewPageState();
}

final class _GalleryVideoPreviewPageState extends State<GalleryVideoPreviewPage>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  Future<bool>? _initFuture;
  bool selected = false;
  var _generation = 0;
  var _appActive = true;
  var _routeCurrent = true;
  var _manualPaused = false;
  Future<void>? _playInFlight;
  Future<void>? _activationInFlight;
  var _activationRevision = 0;
  int? _lease;
  VideoPlaybackReservation? _activationReservation;
  Future<void>? _pauseInFlight;
  final _disposedControllers = Expando<bool>();
  VideoPlayerController? _retiringController;
  late final Future<void> Function() _ownerPause = _pauseForLifecycle;

  VideoPlaybackLeaseCoordinator get _leaseCoordinator =>
      SharedVideoPlayback.wakelockCoordinator;

  /// 压缩产物准备进度（0~1；无进度事件时为 null，展示活动指示器）。
  double? _prepareProgress;

  /// 回退原始视频的明确提示（展示数秒后自动消失）。
  String? _fallbackNotice;
  Timer? _noticeTimer;

  /// 准备阶段文案（压缩中/解码中）。
  String _prepareLabel = '正在准备压缩版…';
  VideoRendition? _ownedRendition;
  PerformanceTrace? _preparationTrace;

  void _cancelPreparationTrace() {
    final trace = _preparationTrace;
    _preparationTrace = null;
    trace?.finish(result: PerformanceResult.cancelled);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _appActive =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    selected = widget.selected;
    _initFuture = _initialize();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final routeCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (_routeCurrent == routeCurrent) return;
    _routeCurrent = routeCurrent;
    if (!routeCurrent) _pauseForInactivitySafely();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    if (!_appActive) _pauseForInactivitySafely();
  }

  bool _isCurrentAttempt(int generation) =>
      mounted && generation == _generation;

  bool get _mayPlay => _appActive && _routeCurrent && !_manualPaused;

  Future<bool> _initialize() async {
    final generation = _generation;
    VideoPlayerController? controller;
    VideoRendition? rendition;
    final trace = widget.traceFactory?.call() ??
        (!widget.viewerOnly &&
                PerformanceTraceRecorder.instance.diagnosticsEnabled
            ? PerformanceTrace.start(
                operation: PerformanceOperationType.videoPrepare)
            : null);
    _preparationTrace = trace;
    trace?.mark(PerformanceStage.videoSelected);
    trace?.mark(PerformanceStage.videoPrepareStarted);
    var result = PerformanceResult.failed;
    if (_isCurrentAttempt(generation)) {
      _prepareProgress = null;
      _prepareLabel = '正在加载视频…';
      _fallbackNotice = null;
    }
    try {
      final originalLoader = widget.loadOriginalFile;
      if (originalLoader != null) {
        try {
          final original = await originalLoader();
          if (!_isCurrentAttempt(generation)) return false;
          if (original != null && await original.exists()) {
            if (!_isCurrentAttempt(generation)) return false;
            rendition = VideoRendition(file: original, usedCompressed: false);
            controller = widget.controllerFactory?.call(original) ??
                VideoPlayerController.file(original);
            trace?.mark(PerformanceStage.decodeStarted);
            await controller.initialize();
          }
        } catch (_) {
          // The asset is borrowed. Failed original decode only retires its
          // player; the independent fallback owns any file it creates.
          await _releaseAttempt(controller, rendition);
          controller = null;
          rendition = null;
        }
        if (!_isCurrentAttempt(generation)) {
          await _releaseAttempt(controller, rendition);
          controller = null;
          rendition = null;
          return false;
        }
      }
      if (controller == null) {
        _prepareLabel = widget.viewerOnly ? '正在加载视频…' : '正在准备压缩版…';
        // The serialized encoder owns the plugin's single-subscription
        // progress stream; the page observes only its scoped callback.
        void onProgress(double value) {
          if (_isCurrentAttempt(generation) &&
              value >= 0 &&
              value <= 1 &&
              _controller == null) {
            setState(() => _prepareProgress = value);
          }
        }

        final loadedRendition =
            await (widget.loadTracedRendition?.call(trace, onProgress) ??
                widget.loadRendition());
        rendition = loadedRendition;
        if (!_isCurrentAttempt(generation)) {
          try {
            await loadedRendition.dispose();
          } finally {
            rendition = null;
          }
          return false;
        }
        if (!loadedRendition.usedCompressed &&
            loadedRendition.fallbackNotice != null) {
          _showNotice(loadedRendition.fallbackNotice!);
        }
        _prepareLabel = '正在解码视频…';
        final initializedController =
            widget.controllerFactory?.call(loadedRendition.file) ??
                VideoPlayerController.file(loadedRendition.file);
        controller = initializedController;
        trace?.mark(PerformanceStage.decodeStarted);
        await initializedController.initialize();
      }
      final initializedController = controller;
      final loadedRendition = rendition!;
      if (!_isCurrentAttempt(generation)) {
        try {
          await _releaseAttempt(initializedController, loadedRendition);
        } finally {
          controller = null;
          rendition = null;
        }
        return false;
      }
      _controller = initializedController;
      _ownedRendition = loadedRendition;
      trace?.mark(PerformanceStage.decodeDone);
      trace?.mark(PerformanceStage.videoPrepareDone);
      setState(() => _controller = initializedController);
      await _playIfAllowed(initializedController, generation);
      result = PerformanceResult.success;
      return true;
    } catch (_) {
      await _releaseAttempt(controller, rendition);
      if (_isCurrentAttempt(generation)) setState(() {});
      return false; // 解码不支持：降级静态预览。
    } finally {
      if (!_isCurrentAttempt(generation)) result = PerformanceResult.cancelled;
      if (identical(_preparationTrace, trace)) {
        _preparationTrace = null;
        trace?.finish(result: result);
      }
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
  Future<void> _retry() async {
    final retryGeneration = ++_generation;
    _cancelPreparationTrace();
    await _releasePreview();
    if (!mounted || retryGeneration != _generation) return;
    setState(() {
      _initFuture = _initialize();
    });
  }

  Future<void> _releasePreview() async {
    final player = _controller;
    final rendition = _ownedRendition;
    final reservation = _activationReservation;
    final lease = _lease;
    _controller = null;
    _ownedRendition = null;
    var nativeDisposeSucceeded = false;
    try {
      await player?.dispose();
      nativeDisposeSucceeded = player != null;
      if (player != null) _disposedControllers[player] = true;
    } catch (error, stackTrace) {
      _retiringController = player;
      if (player != null) {
        SharedVideoPlayback.arbiter.recordFailedPause(_ownerPause);
      }
      FlutterError.reportError(FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'gallery video preview',
        context: ErrorDescription('disposing a gallery video controller'),
      ));
    } finally {
      try {
        await rendition?.dispose();
      } catch (error, stackTrace) {
        FlutterError.reportError(FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'gallery video preview',
            context: ErrorDescription('disposing a gallery rendition')));
      }
      if (identical(_activationReservation, reservation)) {
        _activationReservation = null;
      }
      reservation?.release();
      if (_lease == lease) _lease = null;
      if (lease != null) _leaseCoordinator.revoke(lease);
      if (nativeDisposeSucceeded) {
        if (identical(_retiringController, player)) {
          _retiringController = null;
        }
        if (_retiringController == null) {
          SharedVideoPlayback.arbiter.clearFailedPause(_ownerPause);
        }
      }
    }
  }

  Future<void> _releaseAttempt(
    VideoPlayerController? controller,
    VideoRendition? rendition,
  ) async {
    final ownsController = identical(_controller, controller);
    final ownsRendition = identical(_ownedRendition, rendition);
    final reservation = ownsController ? _activationReservation : null;
    final lease = ownsController ? _lease : null;
    if (ownsController) _controller = null;
    if (ownsRendition) _ownedRendition = null;
    var nativeDisposeSucceeded = false;
    try {
      await controller?.dispose();
      nativeDisposeSucceeded = controller != null;
      if (controller != null) _disposedControllers[controller] = true;
    } catch (error, stackTrace) {
      if (ownsController) {
        _retiringController = controller;
        if (controller != null) {
          SharedVideoPlayback.arbiter.recordFailedPause(_ownerPause);
        }
      }
      FlutterError.reportError(FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'gallery video preview',
          context: ErrorDescription('disposing a gallery video controller')));
    } finally {
      try {
        await rendition?.dispose();
      } catch (error, stackTrace) {
        FlutterError.reportError(FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'gallery video preview',
            context: ErrorDescription('disposing a gallery rendition')));
      }
      if (ownsController && identical(_activationReservation, reservation)) {
        _activationReservation = null;
      }
      reservation?.release();
      if (ownsController && _lease == lease) _lease = null;
      if (lease != null) _leaseCoordinator.revoke(lease);
      if (ownsController && nativeDisposeSucceeded) {
        if (identical(_retiringController, controller)) {
          _retiringController = null;
        }
        if (_retiringController == null) {
          SharedVideoPlayback.arbiter.clearFailedPause(_ownerPause);
        }
      }
    }
  }

  Future<void> _pauseForInactivity() async {
    await _pauseForLifecycle();
  }

  void _pauseForInactivitySafely() {
    unawaited(_pauseForInactivity().catchError((_) {}));
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

  Future<void> _pauseForLifecycleImpl() async {
    final retiring = _retiringController;
    if (retiring != null) {
      try {
        await retiring.pause();
      } catch (_) {
        if (_disposedControllers[retiring] != true) {
          SharedVideoPlayback.arbiter.recordFailedPause(_ownerPause);
          rethrow;
        }
      }
      if (identical(_retiringController, retiring)) {
        _retiringController = null;
        SharedVideoPlayback.arbiter.clearFailedPause(_ownerPause);
      }
      return;
    }
    _activationRevision++;
    final controller = _controller;
    final lease = _lease;
    _lease = null;
    if (lease != null) _leaseCoordinator.revoke(lease);
    final reservation = _activationReservation;
    final retryPause = _ownerPause;
    if (controller == null) {
      if (identical(_activationReservation, reservation)) {
        _activationReservation = null;
      }
      reservation?.release();
      return;
    }
    final pendingPlay = _playInFlight;
    if (pendingPlay != null) {
      try {
        await pendingPlay;
      } catch (_) {
        // Initialization uses its own static-preview fallback for play errors.
      }
    }
    try {
      await controller.pause();
      SharedVideoPlayback.arbiter.clearFailedPause(retryPause);
      if (identical(_retiringController, controller)) {
        _retiringController = null;
      }
    } catch (_) {
      if (_disposedControllers[controller] == true) return;
      SharedVideoPlayback.arbiter.recordFailedPause(retryPause);
      rethrow;
    } finally {
      if (identical(_activationReservation, reservation)) {
        _activationReservation = null;
      }
      reservation?.release();
    }
    if (mounted) setState(() {});
  }

  Future<void> _playIfAllowed(
    VideoPlayerController controller,
    int generation,
  ) {
    final existing = _activationInFlight;
    if (existing != null) return existing;
    late final Future<void> tracked;
    tracked = _playIfAllowedImpl(controller, generation).whenComplete(() {
      if (identical(_activationInFlight, tracked)) {
        _activationInFlight = null;
      }
    });
    _activationInFlight = tracked;
    return tracked;
  }

  Future<void> _playIfAllowedImpl(
    VideoPlayerController controller,
    int generation,
  ) async {
    if (!_isCurrentAttempt(generation) || !_mayPlay) return;
    final intent = ++_activationRevision;
    final pendingPause = _pauseInFlight;
    if (pendingPause != null) await pendingPause;
    if (!_isCurrentAttempt(generation) ||
        !_mayPlay ||
        intent != _activationRevision) {
      return;
    }
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
    if (!_isCurrentAttempt(generation) ||
        !_mayPlay ||
        intent != _activationRevision ||
        !reservation.isCurrent) {
      reservation.release();
      if (identical(_activationReservation, reservation)) {
        _activationReservation = null;
      }
      return;
    }
    final lease = _leaseCoordinator.acquire();
    _lease = lease;
    final play = controller.play();
    _playInFlight = play;
    try {
      await play;
    } catch (_) {
      _leaseCoordinator.revoke(lease);
      if (_lease == lease) _lease = null;
      reservation.release();
      if (identical(_activationReservation, reservation)) {
        _activationReservation = null;
      }
      rethrow;
    } finally {
      if (identical(_playInFlight, play)) _playInFlight = null;
    }
    if (!_isCurrentAttempt(generation) ||
        !_mayPlay ||
        intent != _activationRevision ||
        !reservation.isCurrent ||
        _leaseCoordinator.current != lease) {
      await controller.pause();
      _leaseCoordinator.revoke(lease);
      if (_lease == lease) _lease = null;
      reservation.release();
      if (identical(_activationReservation, reservation)) {
        _activationReservation = null;
      }
    }
  }

  Future<void> _togglePlay() async {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      _manualPaused = true;
      await _pauseForInactivity();
    } else {
      _manualPaused = false;
      await _playIfAllowed(controller, _generation);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _generation++;
    _cancelPreparationTrace();
    WidgetsBinding.instance.removeObserver(this);
    _noticeTimer?.cancel();
    unawaited(_releasePreview());
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
    return WeChatPageScaffold.navigation(
      navigationBar: null,
      showNetworkCapsule: false,
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
                    behavior: HitTestBehavior.opaque,
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
          if (!widget.viewerOnly)
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
                  fit: BoxFit.cover, gaplessPlayback: true),
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
                          widthFactor:
                              _prepareProgress!.clamp(0.02, 1.0).toDouble(),
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
            widget.viewerOnly
                ? '视频加载失败，请返回刷新或重试'
                : '视频准备失败（${_format(widget.duration)}），可重试；重试失败仍可选择发送',
            style: TextStyle(fontSize: 13, color: CupertinoColors.systemGrey),
          ),
          const SizedBox(height: 10),
          CupertinoButton(
            key: const Key('gallery-video-retry'),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            color: WeChatColors.brandPrimary,
            borderRadius: BorderRadius.circular(16),
            onPressed: _retry,
            child: const Text('重试',
                style: TextStyle(fontSize: 14, color: CupertinoColors.white)),
          ),
        ],
      );
}
