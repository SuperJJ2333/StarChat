import 'dart:io';
import 'package:flutter/widgets.dart';
import 'shared_emoji_player.dart';

/// Fixed geometry and a paint-only subscription to the shared frame timeline.
final class SharedEmojiImage extends StatefulWidget {
  const SharedEmojiImage(
      {super.key,
      required this.file,
      required this.size,
      required this.visible,
      required this.fallback,
      this.pool});
  final File file;
  final double size;
  final bool visible;
  final Widget fallback;
  final SharedEmojiPlayerPool? pool;
  @override
  State<SharedEmojiImage> createState() => _SharedEmojiImageState();
}

final class _SharedEmojiImageState extends State<SharedEmojiImage> {
  EmojiPlayback? _playback;
  int? _size;
  bool _ready = false, _failed = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void didUpdateWidget(covariant SharedEmojiImage old) {
    super.didUpdateWidget(old);
    if (old.file.path != widget.file.path || old.pool != widget.pool) _unbind();
    _bind();
  }

  void _bind() {
    final size = SharedEmojiPlayerPool.decodeSize(
        (widget.size * MediaQuery.devicePixelRatioOf(context)).ceil());
    if (_size != size) _unbind();
    if (_playback == null) {
      _size = size;
      _playback = (widget.pool ?? SharedEmojiPlayerPool.instance)
          .subscribe(widget.file, size);
      // Initial attachment may notify synchronously; no listener until after it.
      _playback!.setVisible(widget.visible);
      _ready = _playback!.frame != null;
      _failed = _playback!.failed;
      _playback!.addListener(_availabilityChanged);
    } else {
      _playback!.setVisible(widget.visible);
    }
  }

  void _availabilityChanged() {
    final ready = _playback?.frame != null;
    // Only availability changes rebuild fallback. Animation frames repaint.
    final failed = _playback?.failed ?? false;
    if (mounted && (ready != _ready || failed != _failed)) {
      setState(() {
        _ready = ready;
        _failed = failed;
      });
    }
  }

  void _unbind() {
    _playback?.removeListener(_availabilityChanged);
    _playback?.dispose();
    _playback = null;
    _size = null;
    _ready = false;
  }

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.size,
        height: widget.size,
        child: RepaintBoundary(
            child: Stack(fit: StackFit.expand, children: [
          if (!_ready && _failed) widget.fallback,
          CustomPaint(painter: _EmojiPainter(_playback!)),
        ])),
      );
}

final class _EmojiPainter extends CustomPainter {
  _EmojiPainter(this.playback) : super(repaint: playback);
  final EmojiPlayback playback;
  @override
  void paint(Canvas canvas, Size size) {
    final frame = playback.frame;
    if (frame == null) return;
    paintImage(
        canvas: canvas,
        rect: Offset.zero & size,
        image: frame,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.low);
  }

  @override
  bool shouldRepaint(covariant _EmojiPainter old) => old.playback != playback;
}
