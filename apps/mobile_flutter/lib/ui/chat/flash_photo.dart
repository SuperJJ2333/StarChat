import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/matrix/screen_capture_protection.dart';

/// 闪照（阅后即焚图片）：
/// - 气泡缩略图 = 低分辨率解码 + 最近邻放大的马赛克，中央闪电角标；
/// - 未销毁时点击进入查看页：马赛克 + 「长按屏幕可查看 3 秒」；
/// - 长按显示原图（带轻量动态水印），右上角 3 秒圆圈倒计时；松手或超时
///   立即销毁且不可重新查看；
/// - 查看期间申请安全窗口租约（Android FLAG_SECURE）；iOS 录屏/镜像或
///   系统截图（截图是**事后**通知）会立即隐藏原图并销毁；
/// - 销毁后气泡叠加「闪照已销毁」，不可再次打开，也不可转发。
///
/// 原图仅通过端到端加密事件传输；本组件不提供保存/转发入口。
/// 明确边界：无法阻止另一台设备拍摄屏幕、root/越狱或系统级 hook。

/// 阅后即焚标记（按账号 + 事件 ID 持久化；上限防无限增长）。
final class FlashPhotoViewedStore {
  FlashPhotoViewedStore._(this._prefs, this._key);

  static const _maxEntries = 500;
  static const _prefix = 'flash-viewed';

  final SharedPreferences _prefs;
  final String _key;
  final Set<String> _viewed = <String>{};
  final _listeners = <VoidCallback>{};

  static Future<FlashPhotoViewedStore> load(String accountKey) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_prefix:$accountKey';
    final store = FlashPhotoViewedStore._(prefs, key);
    store._viewed.addAll(prefs.getStringList(key) ?? const <String>[]);
    return store;
  }

  bool isViewed(String eventId) => _viewed.contains(eventId);

  void markViewed(String eventId) {
    if (!_viewed.add(eventId)) return;
    if (_viewed.length > _maxEntries) {
      _viewed.remove(_viewed.first);
    }
    _prefs.setStringList(_key, _viewed.toList(growable: false));
    for (final listener in _listeners.toList(growable: false)) {
      listener();
    }
  }

  void addListener(VoidCallback listener) => _listeners.add(listener);
  void removeListener(VoidCallback listener) => _listeners.remove(listener);
}

/// 马赛克渲染：极低分辨率解码（默认 26px 宽）+ 最近邻放大成块状像素。
final class FlashMosaicImage extends StatelessWidget {
  const FlashMosaicImage(
      {super.key, required this.bytes, this.mosaicWidth = 26});

  final Uint8List bytes;
  final int mosaicWidth;

  @override
  Widget build(BuildContext context) => Image(
        key: const Key('flash-mosaic-image'),
        image: ResizeImage(MemoryImage(bytes),
            width: mosaicWidth, policy: ResizeImagePolicy.exact),
        filterQuality: FilterQuality.none,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => Container(
          color: const Color(0xFF3A3A3C),
          alignment: Alignment.center,
          child: const Icon(CupertinoIcons.bolt_fill,
              size: 36, color: CupertinoColors.systemYellow),
        ),
      );
}

/// 闪电角标：马赛克中央的黄色闪电圆片。
final class FlashBoltBadge extends StatelessWidget {
  const FlashBoltBadge({super.key, this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('flash-bolt-badge'),
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: Color(0xCC1B1B1D),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(CupertinoIcons.bolt_fill,
            size: size * .55, color: CupertinoColors.systemYellow),
      );
}

/// 聊天气泡中的闪照缩略（不响应点击；打开逻辑由外层根据销毁态决定）。
final class FlashPhotoBubble extends StatefulWidget {
  const FlashPhotoBubble({
    super.key,
    required this.loadOriginal,
    required this.viewed,
    this.width = 180,
    this.height = 220,
  });

  /// 解密加载原图字节（调用方负责内存缓存；闪照不走磁盘预览缓存）。
  final Future<Uint8List> Function() loadOriginal;
  final bool viewed;
  final double width;
  final double height;

  @override
  State<FlashPhotoBubble> createState() => _FlashPhotoBubbleState();
}

final class _FlashPhotoBubbleState extends State<FlashPhotoBubble> {
  Uint8List? _bytes;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.loadOriginal();
      if (mounted) setState(() => _bytes = bytes);
    } catch (_) {
      if (mounted) setState(() => _error = '闪照加载失败');
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        key: const Key('flash-photo-bubble'),
        width: widget.width,
        height: widget.height,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: const Color(0xFF2C2C2E),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Stack(fit: StackFit.expand, children: [
            if (_bytes != null)
              FlashMosaicImage(bytes: _bytes!)
            else if (_error != null)
              Center(
                  child: Text(_error!,
                      style: const TextStyle(
                          fontSize: 12, color: CupertinoColors.systemGrey)))
            else
              const Center(child: CupertinoActivityIndicator(radius: 9)),
            const Center(child: FlashBoltBadge()),
            if (widget.viewed)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: const Color(0xB31B1B1D),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  alignment: Alignment.center,
                  child: const Text('闪照已销毁',
                      key: Key('flash-destroyed-caption'),
                      style: TextStyle(
                          fontSize: 11, color: CupertinoColors.systemGrey5)),
                ),
              ),
          ]),
        ),
      );
}

/// 3 秒圆圈倒计时（闪电 + 环形进度）。
final class FlashCountdownRing extends StatelessWidget {
  const FlashCountdownRing({super.key, required this.remaining, this.total});

  final Duration remaining;
  final Duration? total;

  @override
  Widget build(BuildContext context) {
    final span = (total ?? FlashPhotoViewerPage.viewDuration).inMilliseconds;
    final progress = span <= 0 ? 0.0 : remaining.inMilliseconds / span;
    return SizedBox(
      key: const Key('flash-countdown-ring'),
      width: 44,
      height: 44,
      child: CustomPaint(
        painter: _RingPainter(progress.clamp(0.0, 1.0)),
        child: const Center(
          child: Icon(CupertinoIcons.bolt_fill,
              size: 18, color: CupertinoColors.systemYellow),
        ),
      ),
    );
  }
}

final class _RingPainter extends CustomPainter {
  const _RingPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final deflated = rect.deflate(3);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = const Color(0x66FFFFFF);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3
      ..color = const Color(0xFFFFCC00);
    canvas.drawArc(deflated, -1.5708, 6.2832, false, track);
    canvas.drawArc(deflated, -1.5708, 6.2832 * progress, false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress;
}

/// 原图 reveal 时的轻量动态水印（威慑用，不是主要安全机制）。
/// 不含手机号/邮箱/token/Matrix ID/内部 userId。
final class FlashWatermark extends StatelessWidget {
  const FlashWatermark({super.key, this.phase = 0});

  /// 位置相位（0..2）：轻微移动，避免固定叠在脸部中央。
  final int phase;

  @override
  Widget build(BuildContext context) {
    final alignment = switch (phase % 3) {
      0 => Alignment.topLeft,
      1 => Alignment.centerRight,
      _ => Alignment.bottomCenter,
    };
    return IgnorePointer(
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Transform.rotate(
            angle: -0.35,
            child: Text(
              '闪照 · 仅限当前查看',
              key: const Key('flash-watermark'),
              style: TextStyle(
                fontSize: 13,
                color: CupertinoColors.white.withValues(alpha: 0.28),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 闪照查看页：马赛克 → 长按 3 秒原图（带水印）→ 销毁。
///
/// 安全行为：
/// - 进入即申请安全窗口租约（Android FLAG_SECURE 在用户长按之前就已开启）；
/// - iOS 录屏/镜像进行中：禁止 reveal，长按无效并提示；
/// - reveal 期间检测到开始录屏/镜像、系统截图（事后信号）或应用退到后台：
///   立即隐藏原图、取消倒计时、标记已查看并销毁，且不可恢复。
final class FlashPhotoViewerPage extends StatefulWidget {
  const FlashPhotoViewerPage(
      {super.key,
      required this.loadOriginal,
      this.onDestroyed,
      this.protection});

  static const viewDuration = Duration(seconds: 3);

  final Future<Uint8List> Function() loadOriginal;
  final VoidCallback? onDestroyed;

  /// 屏幕捕获保护服务（默认生产单例；测试注入假实现）。
  final ScreenCaptureProtection? protection;

  @override
  State<FlashPhotoViewerPage> createState() => _FlashPhotoViewerPageState();
}

final class _FlashPhotoViewerPageState extends State<FlashPhotoViewerPage>
    with WidgetsBindingObserver {
  Uint8List? _bytes;
  bool _revealed = false;
  bool _destroyed = false;
  Duration _remaining = FlashPhotoViewerPage.viewDuration;
  Timer? _countdown;
  ScreenCaptureProtection get _protection =>
      widget.protection ?? ScreenCaptureProtection.instance;
  ScreenCaptureLease? _lease;
  StreamSubscription<void>? _screenshotSubscription;
  int _watermarkPhase = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 必须在任何 reveal 之前就把安全窗口打开（不等长按）。
    _acquireLease();
    _protection.captureActive.addListener(_captureChanged);
    _screenshotSubscription = _protection.screenshots.listen((_) {
      _destroyForCapture();
    });
    _load();
  }

  Future<void> _acquireLease() async {
    try {
      final lease = await _protection.acquire();
      if (!mounted) {
        await lease.release();
        return;
      }
      _lease = lease;
    } catch (_) {
      // 平台不支持时不阻断查看流程（Android 无 Google Play 服务等场景）。
    }
  }

  void _captureChanged() {
    if (!mounted) return;
    if (_protection.captureActive.value) {
      _destroyForCapture();
      return;
    }
    // 录屏/镜像结束：刷新提示与长按可用性（若已销毁则不可恢复）。
    setState(() {});
  }

  /// 录屏/镜像开始、系统截图（事后）、退到后台：立即销毁，绝不等倒计时。
  void _destroyForCapture() {
    if (!mounted || _destroyed) return;
    _countdown?.cancel();
    _countdown = null;
    setState(() {
      _revealed = false;
      _destroyed = true;
      _bytes = null; // 释放 original 引用（Dart 不保证物理清零）。
    });
    widget.onDestroyed?.call();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 安全优先：reveal 状态下切后台/失去焦点立即销毁，回前台不自动恢复。
    if (state != AppLifecycleState.resumed) {
      if (_revealed) _destroyForCapture();
      return;
    }
    // 回前台：Activity/场景重建可能丢过 FLAG_SECURE，重申安全窗口。
    if (_lease != null) unawaited(_protection.reassert());
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.loadOriginal();
      if (!mounted || _destroyed) return;
      setState(() => _bytes = bytes);
    } catch (_) {
      if (mounted) setState(() => _destroyed = true);
    }
  }

  void _startReveal() {
    if (_destroyed || _revealed || _bytes == null) return;
    if (_protection.captureActive.value) return; // 录屏中禁止 reveal
    setState(() {
      _revealed = true;
      _remaining = FlashPhotoViewerPage.viewDuration;
      _watermarkPhase = (_watermarkPhase + 1) % 3;
    });
    _countdown?.cancel();
    var elapsedMs = 0;
    const tick = Duration(milliseconds: 100);
    _countdown = Timer.periodic(tick, (timer) {
      elapsedMs += tick.inMilliseconds;
      if (!mounted) return;
      setState(() => _remaining = FlashPhotoViewerPage.viewDuration -
          Duration(milliseconds: elapsedMs));
      if (elapsedMs >= FlashPhotoViewerPage.viewDuration.inMilliseconds) {
        _stopReveal();
      }
    });
  }

  void _stopReveal() {
    _countdown?.cancel();
    _countdown = null;
    if (!mounted) return;
    final wasRevealed = _revealed || _destroyed == false;
    setState(() {
      _revealed = false;
      _destroyed = true;
    });
    if (wasRevealed) widget.onDestroyed?.call();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _protection.captureActive.removeListener(_captureChanged);
    _screenshotSubscription?.cancel();
    _screenshotSubscription = null;
    _countdown?.cancel();
    unawaited(_lease?.release());
    _lease = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        key: const Key('flash-photo-viewer'),
        backgroundColor: CupertinoColors.black,
        child: SafeArea(
          child: Stack(children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.pop(context),
                // 录屏/镜像进行中或已销毁：长按无效（不 reveal）。
                onLongPressStart: (_destroyed ||
                        _protection.captureActive.value)
                    ? null
                    : (_) => _startReveal(),
                onLongPressEnd: (_) {
                  if (_revealed) _stopReveal();
                },
                onLongPressCancel: () {
                  if (_revealed) _stopReveal();
                },
                child: _destroyed
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(CupertinoIcons.bolt_fill,
                                size: 34, color: CupertinoColors.systemGrey),
                            const SizedBox(height: 10),
                            Text(
                              '闪照已销毁',
                              key: const Key('flash-viewer-destroyed'),
                              style: const TextStyle(
                                  fontSize: 14,
                                  color: CupertinoColors.systemGrey5),
                            ),
                          ],
                        ),
                      )
                    : _bytes == null
                        ? const Center(child: CupertinoActivityIndicator())
                        : _revealed
                            ? Stack(fit: StackFit.expand, children: [
                                Center(
                                  child: Image(
                                    key: const Key('flash-revealed-image'),
                                    image: MemoryImage(_bytes!),
                                    filterQuality: FilterQuality.medium,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                                FlashWatermark(phase: _watermarkPhase),
                              ])
                            : Center(
                                child: AspectRatio(
                                  aspectRatio: 3 / 4,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      FlashMosaicImage(bytes: _bytes!),
                                      const Center(
                                          child: FlashBoltBadge(size: 56)),
                                    ],
                                  ),
                                ),
                              ),
              ),
            ),
            Positioned(
              top: 8,
              right: 12,
              child: _revealed
                  ? FlashCountdownRing(remaining: _remaining)
                  : CupertinoButton(
                      key: const Key('flash-viewer-close'),
                      padding: EdgeInsets.zero,
                      onPressed: () => Navigator.pop(context),
                      child: const Icon(CupertinoIcons.xmark,
                          size: 20, color: CupertinoColors.white),
                    ),
            ),
            if (!_revealed && !_destroyed && _bytes != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 48,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0x661B1B1D),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      flashViewerHintText(
                          destroyed: _destroyed,
                          captureActive: _protection.captureActive.value),
                      key: Key(_protection.captureActive.value
                          ? 'flash-capture-blocked'
                          : 'flash-hold-hint'),
                      style: const TextStyle(
                          fontSize: 12, color: CupertinoColors.systemGrey5),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      );
}

/// 闪照查看页提示文案（可单测）：
/// 正在录屏/镜像 → 明确不可查看；否则长按提示（3 秒）。
String flashViewerHintText(
    {required bool destroyed, required bool captureActive}) {
  if (destroyed) return '闪照已销毁';
  if (captureActive) return '正在录屏或共享屏幕，无法查看闪照';
  return '长按屏幕可查看 ${FlashPhotoViewerPage.viewDuration.inSeconds} 秒';
}
