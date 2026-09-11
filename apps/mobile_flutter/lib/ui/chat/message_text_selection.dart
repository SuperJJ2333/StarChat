import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';

import 'message_action.dart';
import 'message_bubble_menu.dart';
import 'message_menu_placement.dart';
import 'message_selection_offset_mapper.dart';

/// 长按文本消息的复制选框（规格 #5）：
/// - RoomPage 为每条文本消息创建一个会话；完整选择显示由 [fullActions]
///   定义的原功能菜单，局部选择显示复制/全选/引用/转发；
/// - 本组件负责选区背景、左右拖动手柄、拖动时放大镜和统一菜单锚点，
///   确保任意时刻只有一个 overlay 会话；
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
    required this.fullActions,
    required this.onAction,
    required this.onDismissed,
  });

  final OverlayState overlay;
  final String text;
  final GlobalKey textKey;
  final Rect messageRect;
  final bool isOwn;
  final Set<MessageAction> fullActions;
  final void Function(MessageAction action, String? selectedText) onAction;
  final VoidCallback onDismissed;

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
    required Set<MessageAction> fullActions,
    required void Function(MessageAction action, String? selectedText) onAction,
    required VoidCallback onDismissed,
  }) {
    dismissActive();
    final session = MessageTextSelectionSession._(
      overlay: Overlay.of(roomContext, rootOverlay: true),
      text: text,
      textKey: textKey,
      messageRect: messageRect,
      isOwn: isOwn,
      fullActions: fullActions,
      onAction: onAction,
      onDismissed: onDismissed,
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
  Offset? _finger;
  static const Size _magnifierSize = Size(116, 64);
  MessageMenuPlacement? _compactMenuPlacementResult;

  late final MessageSelectionOffsetMapper _offsetMapper =
      MessageSelectionOffsetMapper(widget.session.text);
  late final List<int> _boundaries = _offsetMapper.sourceBoundaries;

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
    final (sourceStart, sourceEnd) = _normalized;
    final (start, end) =
        _offsetMapper.renderSelectionForSourceRange(sourceStart, sourceEnd);
    if (paragraph == null || end <= start) return const [];
    final overlayRender = _overlay.context.findRenderObject();
    return paragraph
        .getBoxesForSelection(TextSelection(
            baseOffset: start.clamp(0, _offsetMapper.renderLength),
            extentOffset: end.clamp(0, _offsetMapper.renderLength)))
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

  int _previousBoundary(int value) {
    for (var i = _boundaries.length - 1; i >= 0; i--) {
      if (_boundaries[i] < value) return _boundaries[i];
    }
    return 0;
  }

  int _nextBoundary(int value) {
    for (final bound in _boundaries) {
      if (bound > value) return bound;
    }
    return widget.session.text.length;
  }

  bool get _isCollapsed {
    final (start, end) = _normalized;
    return start == end;
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
      _compactMenuPlacementResult = null;
    });
  }

  void _setAnchor(_Handle handle, Offset global) {
    final paragraph = _paragraph;
    if (paragraph == null) return;
    final local = paragraph.globalToLocal(global);
    final renderPosition = paragraph.getPositionForOffset(local).offset;
    final sourceRange = _offsetMapper.sourceRangeForRenderSelection(
      renderPosition,
      renderPosition,
    );
    var position = handle == _Handle.start ? sourceRange.$1 : sourceRange.$2;
    // 字素对齐：手柄落点吸附到字素边界，避免选中半个 emoji/字符。
    position = handle == _Handle.start
        ? _floorBoundary(position)
        : _ceilBoundary(position);
    setState(() {
      if (handle == _Handle.start) {
        _anchorStart =
            position >= _anchorEnd ? _previousBoundary(_anchorEnd) : position;
      } else {
        _anchorEnd =
            position <= _anchorStart ? _nextBoundary(_anchorStart) : position;
      }
      final full = _isFull;
      if (full != _fullSelection) {
        _fullSelection = full;
        _compactMenuPlacementResult = null;
      }
    });
  }

  void _cancel() => widget.session.dismiss();

  MessageMenuPlacement? _menuPlacement(Rect selectionBounds, Size menuSize) {
    final media = MediaQuery.of(context);
    final overlayBox = _overlay.context.findRenderObject() as RenderBox?;
    if (overlayBox == null) return null;
    return MessageMenuPlacement.calculate(
      anchor: selectionBounds,
      viewport: Rect.fromLTRB(
          8,
          media.padding.top + 8,
          overlayBox.size.width - 8,
          overlayBox.size.height -
              media.viewInsets.bottom -
              media.padding.bottom -
              8),
      menuSize: menuSize,
      outgoing: widget.session.isOwn,
    );
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
        : (dx: rects.last.right, dy: rects.last.top, height: rects.last.height);
    final dragging = _dragging != _Handle.none;
    final handleTargetsOverlap =
        _handleHitRect(startAnchor).overlaps(_handleHitRect(endAnchor));
    final showCompactMenu = !_fullSelection && !_isCollapsed && !dragging;
    final showFullMenu = _fullSelection && !dragging;
    final fullPlacement = showFullMenu
        ? _menuPlacement(
            widget.session.messageRect,
            Size(272, widget.session.fullActions.length > 4 ? 128 : 72),
          )
        : null;
    if (showCompactMenu && _compactMenuPlacementResult == null) {
      _compactMenuPlacementResult = _menuPlacement(bounds, const Size(272, 72));
    }
    // 放大镜位置先按屏幕钳位，再以钳位后的镜片中心计算焦点，
    // 保证任何位置都精确放大手指覆盖区域。
    final media = MediaQuery.of(context);
    final overlayBox = _overlay.context.findRenderObject() as RenderBox?;
    final finger = _finger == null || overlayBox == null
        ? null
        : overlayBox.globalToLocal(_finger!);
    final lensOuterWidth = _magnifierSize.width + 6;
    final lensOuterHeight = _magnifierSize.height + 6;
    final lensBottom = overlayBox == null
        ? media.size.height - 4
        : overlayBox.size.height -
            media.viewInsets.bottom -
            media.padding.bottom -
            4;
    final magnifierLeft = _finger == null
        ? 0.0
        : (finger!.dx - lensOuterWidth / 2)
            .clamp(4.0, media.size.width - lensOuterWidth - 4);
    final magnifierTop = _finger == null
        ? 0.0
        : (finger!.dy - lensOuterHeight - 20)
            .clamp(media.padding.top + 4, lensBottom - lensOuterHeight);
    return Stack(children: [
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
          child: const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(color: Color(0x331AAD19)),
            ),
          ),
        ),
      // 左右手柄：分别锚定选区首行左缘、末行右缘（微信样式：
      // 左柄圆点在下、右柄圆点在上）。
      _handle(
        key: const Key('selection-handle-start'),
        anchor: startAnchor,
        handle: _Handle.start,
        dotAtBottom: true,
        interactive: !handleTargetsOverlap,
      ),
      _handle(
        key: const Key('selection-handle-end'),
        anchor: endAnchor,
        handle: _Handle.end,
        dotAtBottom: false,
        interactive: !handleTargetsOverlap,
      ),
      if (handleTargetsOverlap)
        _handleHitLayer(startAnchor: startAnchor, endAnchor: endAnchor),
      if (fullPlacement != null)
        _buildMenu(
          placement: fullPlacement,
          actions: widget.session.fullActions,
          onSelected: (action) {
            widget.session.dismiss();
            widget.session.onAction(action, null);
          },
        ),
      // 局部选择菜单：复制/全选/引用/转发，锚定选区。
      if (showCompactMenu && _compactMenuPlacementResult != null)
        _buildMenu(
          placement: _compactMenuPlacementResult!,
          actions: const {
            MessageAction.copy,
            MessageAction.selectAll,
            MessageAction.reply,
            MessageAction.forward,
          },
          orderOverride: const [
            MessageAction.copy,
            MessageAction.selectAll,
            MessageAction.reply,
            MessageAction.forward,
          ],
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
      // 放大镜：拖动手柄期间跟随手指，放大手指覆盖的文字区域
      // （镜片悬于手指上方避让）；松手/取消立即消失（不残留）。
      if (dragging && _finger != null)
        Positioned(
          left: magnifierLeft,
          top: magnifierTop,
          child: IgnorePointer(
            child: _SelectionMagnifier(
              size: _magnifierSize,
              focalPointOffset: finger! -
                  Offset(magnifierLeft + 3 + _magnifierSize.width / 2,
                      magnifierTop + 3 + _magnifierSize.height / 2),
            ),
          ),
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
    required bool interactive,
  }) {
    final hitHeight =
        (anchor.height + 12).clamp(44.0, double.infinity).toDouble();
    final lineTop = (hitHeight - anchor.height) / 2;
    final visual = SizedBox(
      width: 44,
      height: hitHeight,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(
          left: (44 - 2.5) / 2,
          top: lineTop,
          width: 2.5,
          height: anchor.height,
          child: const ColoredBox(color: Color(0xFF1AAD19)),
        ),
        Positioned(
          left: 16,
          top: dotAtBottom ? lineTop + anchor.height - 6 : lineTop - 6,
          child: _handleDot(active: _dragging == handle),
        ),
      ]),
    );
    return Positioned(
      key: key,
      left: anchor.dx - 22,
      top: anchor.dy + anchor.height / 2 - hitHeight / 2,
      width: 44,
      height: hitHeight,
      // 视觉与 44px 命中层分离：短消息两个命中层重叠时由下方的
      // 统一路由层按离手柄中心最近的端点选择，避免后绘制的右柄吞掉左柄。
      child: interactive
          ? Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) => _startDrag(handle, event.position),
              onPointerMove: (event) => _updateDrag(handle, event.position),
              onPointerUp: (_) => _finishDrag(),
              onPointerCancel: (_) => _finishDrag(),
              child: visual,
            )
          : IgnorePointer(child: visual),
    );
  }

  Widget _buildMenu({
    required MessageMenuPlacement placement,
    required Set<MessageAction> actions,
    required ValueChanged<MessageAction> onSelected,
    List<MessageAction>? orderOverride,
  }) =>
      Positioned.fromRect(
        rect: placement.rect,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 120),
          builder: (_, value, child) => Opacity(
            opacity: value,
            child: Transform.scale(scale: .96 + .04 * value, child: child),
          ),
          child: MessageBubbleMenu(
            actions: actions,
            orderOverride: orderOverride,
            arrowAtTop: placement.arrowAtTop,
            arrowX: placement.arrowX,
            onSelected: onSelected,
          ),
        ),
      );

  Rect _handleHitRect(({double dx, double dy, double height}) anchor) {
    final height = (anchor.height + 12).clamp(44.0, double.infinity);
    return Rect.fromLTWH(
      anchor.dx - 22,
      anchor.dy + anchor.height / 2 - height / 2,
      44,
      height,
    );
  }

  void _startDrag(_Handle handle, Offset globalPosition) {
    setState(() {
      _dragging = handle;
      _finger = globalPosition;
    });
  }

  void _updateDrag(_Handle handle, Offset globalPosition) {
    if (_dragging != handle) return;
    _setAnchor(handle, globalPosition);
    setState(() => _finger = globalPosition);
  }

  Widget _handleHitLayer({
    required ({double dx, double dy, double height}) startAnchor,
    required ({double dx, double dy, double height}) endAnchor,
  }) {
    final startRect = _handleHitRect(startAnchor);
    final endRect = _handleHitRect(endAnchor);
    final bounds = startRect.expandToInclude(endRect);
    _Handle? nearestHandle(Offset globalPosition) {
      final overlayBox = _overlay.context.findRenderObject() as RenderBox?;
      if (overlayBox == null) return null;
      final position = overlayBox.globalToLocal(globalPosition);
      final hitsStart = startRect.contains(position);
      final hitsEnd = endRect.contains(position);
      if (!hitsStart && !hitsEnd) return null;
      if (hitsStart && !hitsEnd) return _Handle.start;
      if (hitsEnd && !hitsStart) return _Handle.end;
      final startCenter =
          Offset(startAnchor.dx, startAnchor.dy + startAnchor.height / 2);
      final endCenter =
          Offset(endAnchor.dx, endAnchor.dy + endAnchor.height / 2);
      return (position - startCenter).distanceSquared <=
              (position - endCenter).distanceSquared
          ? _Handle.start
          : _Handle.end;
    }

    return Positioned.fromRect(
      rect: bounds,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          final handle = nearestHandle(event.position);
          if (handle == null) return;
          setState(() {
            _dragging = handle;
            _finger = event.position;
          });
        },
        onPointerMove: (event) {
          final handle = _dragging;
          if (handle == _Handle.none) return;
          _setAnchor(handle, event.position);
          setState(() => _finger = event.position);
        },
        onPointerUp: (_) => _finishDrag(),
        onPointerCancel: (_) => _finishDrag(),
        child: const SizedBox.expand(),
      ),
    );
  }

  void _finishDrag() {
    setState(() {
      _dragging = _Handle.none;
      _finger = null;
      _compactMenuPlacementResult = null;
    });
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

/// 微信风格选择放大镜：RawMagnifier 采样镜片下方真实画面，
/// 焦点为手指覆盖区域；白色描边胶囊外形，随手指移动。
final class _SelectionMagnifier extends StatelessWidget {
  const _SelectionMagnifier({
    required this.size,
    required this.focalPointOffset,
  });

  final Size size;
  final Offset focalPointOffset;

  @override
  Widget build(BuildContext context) => Container(
        width: size.width + 6,
        height: size.height + 6,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size.height / 2 + 3),
          border: Border.all(color: const Color(0xFFFFFFFF), width: 3),
          boxShadow: const [
            BoxShadow(color: Color(0x33000000), blurRadius: 8),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(size.height / 2),
          child: RawMagnifier(
            magnificationScale: 1.75,
            focalPointOffset: focalPointOffset,
            size: size,
          ),
        ),
      );
}
