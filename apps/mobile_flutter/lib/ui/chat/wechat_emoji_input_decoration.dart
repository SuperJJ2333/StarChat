import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';

import '../../features/emoji/fluent_emoji_catalog.dart';
import '../../features/emoji/fluent_vector_emoji_catalog.dart';
import 'emoji_text.dart';
import 'emoji_text_controller.dart';

const _emojiGlyphSizeFactor = 1.18;

/// Paints catalog emoji over an EditableText without changing its text model.
///
/// The child still lays out the original emoji code units (made transparent by
/// [EmojiEditingController]); this overlay is ignored by hit testing and
/// semantics, so the real EditableText exclusively owns pointer, caret,
/// selection, composing and IME behavior.
final class WeChatEmojiInputDecoration extends StatefulWidget {
  const WeChatEmojiInputDecoration({
    super.key,
    required this.controller,
    required this.child,
    this.fontSize = 16,
  });

  final TextEditingController controller;
  final Widget child;
  final double fontSize;

  @override
  State<WeChatEmojiInputDecoration> createState() =>
      _WeChatEmojiInputDecorationState();
}

final class _WeChatEmojiInputDecorationState
    extends State<WeChatEmojiInputDecoration> with WidgetsBindingObserver {
  final _stackKey = GlobalKey();
  List<_EmojiBox> _boxes = const [];
  Rect? _editableViewport;
  ViewportOffset? _editableOffset;
  var _updateScheduled = false;

  EmojiEditingController? get _emojiController =>
      widget.controller is EmojiEditingController
          ? widget.controller as EmojiEditingController
          : null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _emojiController?.attachEmojiOverlay();
    widget.controller.addListener(_handleControllerChange);
    _scheduleUpdate();
  }

  @override
  void didUpdateWidget(WeChatEmojiInputDecoration oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChange);
      if (oldWidget.controller is EmojiEditingController) {
        (oldWidget.controller as EmojiEditingController).detachEmojiOverlay();
      }
      _emojiController?.attachEmojiOverlay();
      widget.controller.addListener(_handleControllerChange);
    }
    _scheduleUpdate();
  }

  @override
  void didChangeMetrics() => _scheduleUpdate();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleUpdate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _editableOffset?.removeListener(_scheduleUpdate);
    widget.controller.removeListener(_handleControllerChange);
    _emojiController?.detachEmojiOverlay();
    super.dispose();
  }

  void _scheduleUpdate() {
    if (_updateScheduled) return;
    _updateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateScheduled = false;
      if (mounted) _updateBoxes();
    });
  }

  void _handleControllerChange() {
    if (widget.controller.text.isEmpty && _boxes.isNotEmpty && mounted) {
      setState(() => _boxes = const []);
    }
    _scheduleUpdate();
  }

  void _updateBoxes() {
    final stack = _stackKey.currentContext?.findRenderObject();
    final editable = stack == null ? null : _findEditable(stack);
    if (stack is! RenderBox || editable == null || !editable.hasSize) return;
    if (!identical(_editableOffset, editable.offset)) {
      _editableOffset?.removeListener(_scheduleUpdate);
      _editableOffset = editable.offset..addListener(_scheduleUpdate);
    }

    final viewport = Rect.fromPoints(
      stack.globalToLocal(editable.localToGlobal(Offset.zero)),
      stack.globalToLocal(
        editable
            .localToGlobal(Offset(editable.size.width, editable.size.height)),
      ),
    );
    final next = <_EmojiBox>[];
    var start = 0;
    for (final grapheme in widget.controller.text.characters) {
      final end = start + grapheme.length;
      final animated = fluentEmojiByChar(grapheme);
      final vector = animated == null ? vectorEmojiByChar(grapheme) : null;
      if (animated != null || vector != null) {
        var boxIndex = 0;
        for (final box in editable.getBoxesForSelection(
          TextSelection(baseOffset: start, extentOffset: end),
        )) {
          final local = stack.globalToLocal(
            editable.localToGlobal(Offset(box.left, box.top)),
          );
          final fontSize =
              (editable.text as TextSpan?)?.style?.fontSize ?? widget.fontSize;
          final size =
              editable.textScaler.scale(fontSize) * _emojiGlyphSizeFactor;
          final rect = Rect.fromLTWH(
            local.dx + ((box.right - box.left) - size) / 2,
            local.dy + ((box.bottom - box.top) - size) / 2,
            size,
            size,
          );
          // A scrolling/max-lines field can report boxes outside its clip.
          if (rect.overlaps(viewport)) {
            next.add(_EmojiBox(
              sourceOffset: start,
              boxIndex: boxIndex,
              rect: rect,
              asset: animated?.asset ?? vector!.asset,
              child: animated != null
                  ? EmojiAnimatedGlyph(asset: animated.asset, size: size)
                  : EmojiVectorGlyph(asset: vector!.asset, size: size),
            ));
          }
          boxIndex++;
        }
      }
      start = end;
    }
    if (!_sameBoxes(_boxes, next) || _editableViewport != viewport) {
      setState(() {
        _boxes = next;
        _editableViewport = viewport;
      });
    }
  }

  RenderEditable? _findEditable(RenderObject object) {
    if (object is RenderEditable) return object;
    RenderEditable? result;
    object.visitChildren((child) => result ??= _findEditable(child));
    return result;
  }

  bool _sameBoxes(List<_EmojiBox> a, List<_EmojiBox> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].rect != b[i].rect || a[i].asset != b[i].asset) {
        return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    // Parent constraints can change without a controller notification.
    _scheduleUpdate();
    return NotificationListener<ScrollNotification>(
      onNotification: (_) {
        _scheduleUpdate();
        return false;
      },
      child: Stack(
        key: _stackKey,
        fit: StackFit.passthrough,
        clipBehavior: Clip.hardEdge,
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: ClipRect(
                  clipper: _EmojiViewportClipper(_editableViewport),
                  child: Stack(
                    children: [
                      for (final box in _boxes)
                        Positioned.fromRect(
                          rect: box.rect,
                          child: KeyedSubtree(
                            key: ValueKey(
                              'emoji-input-glyph-${box.sourceOffset}-${box.boxIndex}',
                            ),
                            child: box.child,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _EmojiViewportClipper extends CustomClipper<Rect> {
  const _EmojiViewportClipper(this.viewport);
  final Rect? viewport;

  @override
  Rect getClip(Size size) => viewport ?? Rect.zero;

  @override
  bool shouldReclip(_EmojiViewportClipper oldClipper) =>
      oldClipper.viewport != viewport;
}

final class _EmojiBox {
  const _EmojiBox({
    required this.sourceOffset,
    required this.boxIndex,
    required this.rect,
    required this.asset,
    required this.child,
  });
  final int sourceOffset;
  final int boxIndex;
  final Rect rect;
  final String asset;
  final Widget child;
}
