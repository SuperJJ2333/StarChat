import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 闪照（阅后即焚图片）：
/// - 气泡缩略图 = 低分辨率解码 + 最近邻放大的马赛克，中央闪电角标；
/// - 未销毁时点击进入查看页：马赛克 + 「长按屏幕可查看 5 秒」；
/// - 长按显示原图，右上角 5 秒圆圈倒计时；松手或超时立即恢复马赛克；
/// - 销毁后气泡叠加「闪照已销毁」，不可再次打开，也不可转发。
///
/// 原图仅通过端到端加密事件传输；本组件不提供保存/转发入口。

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

/// 5 秒圆圈倒计时（闪电 + 环形进度）。
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

/// 闪照查看页：马赛克 → 长按 5 秒原图 → 销毁。
final class FlashPhotoViewerPage extends StatefulWidget {
  const FlashPhotoViewerPage(
      {super.key, required this.loadOriginal, this.onDestroyed});

  static const viewDuration = Duration(seconds: 5);

  final Future<Uint8List> Function() loadOriginal;
  final VoidCallback? onDestroyed;

  @override
  State<FlashPhotoViewerPage> createState() => _FlashPhotoViewerPageState();
}

final class _FlashPhotoViewerPageState extends State<FlashPhotoViewerPage> {
  Uint8List? _bytes;
  bool _revealed = false;
  bool _destroyed = false;
  Duration _remaining = FlashPhotoViewerPage.viewDuration;
  Timer? _countdown;

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
      if (mounted) setState(() => _destroyed = true);
    }
  }

  void _startReveal() {
    if (_destroyed || _revealed || _bytes == null) return;
    setState(() {
      _revealed = true;
      _remaining = FlashPhotoViewerPage.viewDuration;
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
    _countdown?.cancel();
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
                onLongPressStart:
                    _destroyed ? null : (_) => _startReveal(),
                onLongPressEnd: (_) {
                  if (_revealed) _stopReveal();
                },
                onLongPressCancel: () {
                  if (_revealed) _stopReveal();
                },
                child: _bytes == null
                    ? const Center(child: CupertinoActivityIndicator())
                    : _revealed
                        ? Center(
                            child: Image(
                              key: const Key('flash-revealed-image'),
                              image: MemoryImage(_bytes!),
                              filterQuality: FilterQuality.medium,
                              fit: BoxFit.contain,
                            ),
                          )
                        : Center(
                            child: AspectRatio(
                              aspectRatio: 3 / 4,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  FlashMosaicImage(bytes: _bytes!),
                                  const Center(child: FlashBoltBadge(size: 56)),
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
            if (!_revealed && _bytes != null)
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
                      _destroyed ? '闪照已销毁' : '长按屏幕可查看 5 秒',
                      key: Key(_destroyed
                          ? 'flash-viewer-destroyed'
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
