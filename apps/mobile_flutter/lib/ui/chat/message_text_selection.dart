import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';

import 'message_action.dart';
import 'message_bubble_menu.dart';
import 'message_menu_placement.dart';

/// 长按文本消息的复制选框（规格 #5）：
/// - 长按时**原长按功能菜单**仍由 RoomPage 原路径完整渲染（撤回/删除等
///   全部动作、锚定气泡上方），本组件与其同时出现；
/// - 本组件负责：选区背景、左右拖动手柄、拖动时的放大镜，以及
///   “局部选择”（范围 ≠ 整条文字）时的紧凑菜单（复制/全选/引用/转发，
///   锚定选区、避免遮挡选中内容）；
/// - 拖动手柄时回调 [onDragStart]（宿主隐藏原功能菜单），松手后若仍为
///   整条选择则回调 [onFullSelectionRestored]（宿主恢复原功能菜单）；
/// - 选区边界按字素（grapheme）对齐：emoji 中间穿插文字也不会被拆成
///   半个字符（避免复制/引用乱码）；
/// - 空白点击与列表滚动由遮罩取消；切换会话/发送消息由宿主调用
///   [dismissActive] 取消。
final class MessageTextSelectionSession {
  MessageTextSelectionSession._({
    required this.overlay,
    required this.text,
    required this.textKey,
    required this.messageRect,
    required this.isOwn,
    required this.onAction,
    required this.onDismissed,
    required this.onDragStart,
    required this.onFullSelectionRestored,
  });

  final OverlayState overlay;
  final String text;
  final GlobalKey textKey;
  final Rect messageRect;
  final bool isOwn;
  final void Function(MessageAction action, String? selectedText) onAction;
  final VoidCallback onDismissed;
  final VoidCallback onDragStart;
  final VoidCallback onFullSelectionRestored;

  OverlayEntry? _entry;
  final GlobalKey<_SelectionOverlayBodyState> _bodyKey =
      GlobalKey<_SelectionOverlayBodyState>();
  bool _removed = false;

  static MessageTextSelectionSession? _active;

  /// 当前活跃会话（发送消息 / 切换会话时由宿主调用 [dismissActive]）。
  static MessageTextSelectionSession? get active => _active;

  static void show({
    required BuildContext roomContext,
    required String text,
    required GlobalKey textKey,
    required Rect messageRect,
    required bool isOwn,
    required void Function(MessageAction action, String? selectedText)
        onAction,
    required VoidCallback onDismissed,
    required VoidCallback onDragStart,
    required VoidCallback onFullSelectionRestored,
  }) {
    dismissActive();
    final session = MessageTextSelectionSession._(
      overlay: Overlay.of(roomContext, rootOverlay: true),
      text: text,
      textKey: textKey,
      messageRect: messageRect,
      isOwn: isOwn,
      onAction: onAction,
      onDismissed: onDismissed,
      onDragStart: onDragStart,
      onFullSelectionRestored: onFullSelectionRestored,
    );
    _active = session;
    session._entry = OverlayEntry(builder: (_) => session._buildOverlay());
    session.overlay.insert(session._entry!);
  }

  /// 关闭当前会话（发送消息 / 切换会话 / 宿主主动取消）。
  static void dismissActive() => _active?.dismiss();

  void dismiss() {
    if (_removed) return;
    _removed = true;
    _entry?.remove();
    _entry = null;
    if (identical(_active, this)) _active = null;
    onDismissed();
  }

  Widget _buildOverlay() => _SelectionOverlayBody(
        key: _bodyKey,
        session: this,
      );
}

final class _SelectionOverlayBody extends StatefulWidget {
  const _SelectionOverlayBody({super.key, required this.session});

  final MessageTextSelectionSession session;

  @override
  State<_SelectionOverlayBody> createState() => _SelectionOverlayBodyState();
}

final class _SelectionOverlayBodyState extends State<_SelectionOverlayBody> {
  int _anchorStart = 0;
  int _anchorEnd = 0;
  bool _fullSelection = true;
  _Handle _dragging = _Handle.none;
  Offset? _magnifierAnchor;
  Rect _compactMenuRect = Rect.zero;

  late final List<int> _boundaries = _graphemeBoundaries(widget.session.text);

  static List<int> _graphemeBoundaries(String text) {
    final bounds = <int>[0];
    for (final grapheme in text.characters) {
      bounds.add(bounds.last + grapheme.length);
    }
    return bounds;
  }

  int _floorBoundary(int value) {
    for (var i = _boundaries.length - 1; i >= 0; i--) {
      if (_boundaries[i] <= value) return _boundaries[i];
    }
    return 0;
  }

  int _ceilBoundary(int value) {
    for (final bound in _boundaries) {
      if (bound >= value) return bound;
    }
    return value;
  }

  RenderParagraph? get _paragraph {
    final context = widget.session.textKey.currentContext;
    final render = context?.findRenderObject();
    return render is RenderParagraph && render.attached ? render : null;
  }

  OverlayState get _overlay => widget.session.overlay;

  /// 选区行矩形（overlay 坐标）。emoji 的 WidgetSpan 占位盒同样参与，
  /// 跨行/emoji/表情代码均正确。
  List<Rect> _selectionRects() {
    final paragraph = _paragraph;
    final length = widget.session.text.length;
    final (start, end) = _normalized;
    if (paragraph == null || end <= start) return const [];
    final overlayRender = _overlay.context.findRenderObject();
    return paragraph
        .getBoxesForSelection(TextSelection(
            baseOffset: start.clamp(0, length),
            extentOffset: end.clamp(0, length)))
        .map((box) => MatrixUtils.transformRect(
            paragraph.getTransformTo(overlayRender), box.toRect()))
        .toList();
  }

  Rect get _textBox {
    final paragraph = _paragraph;
    final overlayBox = _overlay.context.findRenderObject() as RenderBox?;
    if (paragraph == null || !paragraph.attached || overlayBox == null) {
      return widget.session.messageRect;
    }
    return MatrixUtils.transformRect(
        paragraph.getTransformTo(overlayBox), paragraph.paintBounds);
  }

  /// 字素边界对齐后的归一化选区：保证 substring 不会截断字素。
  (int, int) get _normalized {
    final length = widget.session.text.length;
    final rawStart = _anchorStart.clamp(0, length);
    final rawEnd = _anchorEnd.clamp(0, length);
    final (lo, hi) =
        rawStart <= rawEnd ? (rawStart, rawEnd) : (rawEnd, rawStart);
    return (_floorBoundary(lo), _ceilBoundary(hi));
  }

  bool get _isFull {
    final (start, end) = _normalized;
    return start == 0 && end >= widget.session.text.length;
  }

  @override
  void initState() {
    super.initState();
    _anchorEnd = widget.session.text.length;
    _fullSelection = true;
  }

  void resetToFull() {
    setState(() {
      _anchorStart = 0;
      _anchorEnd = widget.session.text.length;
      _fullSelection = true;
      _compactMenuRect = Rect.zero;
    });
    widget.session.onFullSelectionRestored();
  }

  void _setAnchor(_Handle handle, Offset global) {
    final paragraph = _paragraph;
    if (paragraph == null) return;
    final length = widget.session.text.length;
    final local = paragraph.globalToLocal(global);
    var position =
        paragraph.getPositionForOffset(local).offset.clamp(0, length);
    // 字素对齐：手柄落点吸附到字素边界，避免选中半个 emoji/字符。
    position = handle == _Handle.start
        ? _floorBoundary(position)
        : _ceilBoundary(position);
    setState(() {
      if (handle == _Handle.start) {
        _anchorStart = position;
      } else {
        _anchorEnd = position;
      }
      final full = _isFull;
      if (full != _fullSelection) {
        _fullSelection = full;
        _compactMenuRect = Rect.zero;
      }
    });
  }

  void _cancel() => widget.session.dismiss();

  Rect _compactMenuPlacement(Rect selectionBounds) {
    final media = MediaQuery.of(context);
    final overlayBox = _overlay.context.findRenderObject() as RenderBox?;
    if (overlayBox == null) return Rect.zero;
    final placement = MessageMenuPlacement.calculate(
      anchor: selectionBounds,
      viewport: Rect.fromLTRB(
          8,
          media.padding.top + 8,
          overlayBox.size.width - 8,
          overlayBox.size.height -
              media.viewInsets.bottom -
              media.padding.bottom -
              8),
      menuSize: const Size(272, 72),
      outgoing: widget.session.isOwn,
    );
    return placement.rect;
  }

  @override
  Widget build(BuildContext context) {
    final rects = _selectionRects();
    final bounds = rects.isEmpty ? _textBox : _mergeRects(rects);
    final startAnchor = rects.isEmpty
        ? (dx: bounds.left, dy: bounds.top, height: bounds.height)
        : (
            dx: rects.first.left,
            dy: rects.first.top,
            height: rects.first.height
          );
    final endAnchor = rects.isEmpty
        ? (dx: bounds.right, dy: bounds.bottom, height: bounds.height)
        : (
            dx: rects.last.right,
            dy: rects.last.bottom,
            height: rects.last.height
          );
    final dragging = _dragging != _Handle.none;
    final showCompactMenu = !_fullSelection && !dragging;
    if (showCompactMenu && _compactMenuRect == Rect.zero) {
      _compactMenuRect = _compactMenuPlacement(bounds);
    }
    return Stack(children: [
      // 半透明遮罩：点击空白取消；纵向滚动穿透并触发取消。
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _cancel,
          onVerticalDragStart: (_) => _cancel(),
          child: const SizedBox.expand(),
        ),
      ),
      // 选区背景（微信绿色浅透明）。
      for (final rect in rects)
        Positioned.fromRect(
          rect: rect,
          child: const DecoratedBox(
            decoration: BoxDecoration(color: Color(0x331AAD19)),
          ),
        ),
      // 左右手柄：分别锚定选区首行左缘、末行右缘（微信样式：
      // 左柄圆点在下、右柄圆点在上）。
      _handle(
        key: const Key('selection-handle-start'),
        anchor: startAnchor,
        handle: _Handle.start,
        dotAtBottom: true,
      ),
      _handle(
        key: const Key('selection-handle-end'),
        anchor: endAnchor,
        handle: _Handle.end,
        dotAtBottom: false,
      ),
      // 局部选择菜单：复制/全选/引用/转发，锚定选区。
      if (showCompactMenu && _compactMenuRect != Rect.zero)
        Positioned.fromRect(
          rect: _compactMenuRect,
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: MessageBubbleMenu(
                orderOverride: const [
                  MessageAction.copy,
                  MessageAction.selectAll,
                  MessageAction.reply,
                  MessageAction.forward,
                ],
                arrowAtTop: _compactMenuRect.bottom < bounds.top,
                arrowX: bounds.center.dx - _compactMenuRect.left,
                actions: const {
                  MessageAction.copy,
                  MessageAction.selectAll,
                  MessageAction.reply,
                  MessageAction.forward,
                },
                onSelected: (action) {
                  if (action == MessageAction.selectAll) {
                    resetToFull();
                    return;
                  }
                  final (start, end) = _normalized;
                  final selected = widget.session.text.substring(start, end);
                  widget.session.dismiss();
                  widget.session.onAction(action, selected);
                },
              ),
            ),
          ),
        ),
      // 放大镜：拖动手柄时跟随手柄所在选区边缘，上移避让手指。
      if (dragging && _magnifierAnchor != null)
        Positioned(
          left: (_magnifierAnchor!.dx - 60)
              .clamp(4.0, MediaQuery.of(context).size.width - 124),
          top: _magnifierAnchor!.dy - 118,
          child: const CupertinoMagnifier(),
        ),
    ]);
  }

  Rect _mergeRects(List<Rect> rects) {
    var merged = rects.first;
    for (final rect in rects.skip(1)) {
      merged = merged.expandToInclude(rect);
    }
    return merged;
  }

  Widget _handle({
    required Key key,
    required ({double dx, double dy, double height}) anchor,
    required _Handle handle,
    required bool dotAtBottom,
  }) {
    final active = _dragging == handle;
    return Positioned(
      left: anchor.dx - 14,
      top: dotAtBottom ? anchor.dy - 4 : anchor.dy - anchor.height - 14,
      width: 28,
      height: anchor.height + 18,
      child: GestureDetector(
        key: key,
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) {
          widget.session.onDragStart();
          setState(() => _dragging = handle);
        },
        onPanUpdate: (details) {
          if (_dragging != handle) return;
          _setAnchor(handle, details.globalPosition);
          setState(() {
            final rects = _selectionRects();
            if (rects.isEmpty) {
              _magnifierAnchor = null;
            } else {
              final rect = handle == _Handle.start ? rects.first : rects.last;
              _magnifierAnchor = Offset(
                  handle == _Handle.start ? rect.left : rect.right,
                  rect.top + rect.height / 2);
            }
          });
        },
        onPanEnd: (_) => setState(() {
          _dragging = _Handle.none;
          _magnifierAnchor = null;
          _compactMenuRect = Rect.zero;
        }),
        onPanCancel: () => setState(() {
          _dragging = _Handle.none;
          _magnifierAnchor = null;
        }),
        child: SizedBox(
          width: 28,
          height: anchor.height + 18,
          child: Column(children: [
            if (!dotAtBottom) _handleDot(active: active),
            Expanded(
              child: Center(
                child: Container(
                  width: 2.5,
                  color: const Color(0xFF1AAD19),
                ),
              ),
            ),
            if (dotAtBottom) _handleDot(active: active),
          ]),
        ),
      ),
    );
  }

  Widget _handleDot({required bool active}) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: const Color(0xFF1AAD19),
          shape: BoxShape.circle,
          boxShadow: active
              ? const [BoxShadow(color: Color(0x33000000), blurRadius: 4)]
              : null,
        ),
      );
}

enum _Handle { none, start, end }
