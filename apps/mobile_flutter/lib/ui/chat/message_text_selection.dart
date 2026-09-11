import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';

import 'message_action.dart';
import 'message_bubble_menu.dart';

/// 长按文本消息的复制选框会话（规格 #5）：
/// 菜单与复制选框同时出现；选框左右各一个可拖动手柄，拖动时菜单淡出、
/// 显示放大镜，松开后菜单恢复并按选框位置自适应；选择范围不等于整条
/// 文字时菜单切换为“复制/全选/引用/转发”，操作只作用于选中的文字；
/// 点击空白、滚动消息列表、切换会话、发送消息均取消选择并关闭弹层。
///
/// 选区绘制与手柄定位基于消息文本的 [RenderParagraph]
/// （`getBoxesForSelection` / `getPositionForOffset`），emoji 内联字形
/// （WidgetSpan）按占位盒参与定位，跨行、emoji、表情代码均支持。
final class MessageTextSelectionSession {
  MessageTextSelectionSession._({
    required this.overlay,
    required this.text,
    required this.textKey,
    required this.messageRect,
    required this.fullActions,
    required this.onAction,
    required this.onDismissed,
    required this.isOwn,
  });

  final OverlayState overlay;
  final String text;
  final GlobalKey textKey;
  final Rect messageRect;
  final Set<MessageAction> fullActions;
  final void Function(MessageAction action, String? selectedText) onAction;
  final VoidCallback onDismissed;
  final bool isOwn;

  OverlayEntry? _entry;
  final GlobalKey<_SelectionOverlayBodyState> _bodyKey =
      GlobalKey<_SelectionOverlayBodyState>();
  bool _removed = false;

  static MessageTextSelectionSession? _active;

  /// 当前活跃会话（发送/切换会话时由宿主调用 [dismissActive] 取消）。
  static MessageTextSelectionSession? get active => _active;

  static void show({
    required BuildContext roomContext,
    required String text,
    required GlobalKey textKey,
    required Rect messageRect,
    required Set<MessageAction> fullActions,
    required void Function(MessageAction action, String? selectedText)
        onAction,
    required VoidCallback onDismissed,
    required bool isOwn,
  }) {
    dismissActive();
    final session = MessageTextSelectionSession._(
      overlay: Overlay.of(roomContext, rootOverlay: true),
      text: text,
      textKey: textKey,
      messageRect: messageRect,
      fullActions: fullActions,
      onAction: onAction,
      onDismissed: onDismissed,
      isOwn: isOwn,
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

  /// “全选”：恢复选中整条文字，菜单恢复为完整长按菜单。
  void resetToFullSelection() => _bodyKey.currentState?.resetToFull();

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

  RenderParagraph? get _paragraph {
    final context = widget.session.textKey.currentContext;
    final render = context?.findRenderObject();
    return render is RenderParagraph && render.attached ? render : null;
  }

  OverlayState get _overlay => widget.session.overlay;

  Rect get _textBox {
    final paragraph = _paragraph;
    final overlayBox =
        _overlay.context.findRenderObject() as RenderBox?;
    if (paragraph == null || !paragraph.attached || overlayBox == null) {
      return widget.session.messageRect;
    }
    return MatrixUtils.transformRect(
        paragraph.getTransformTo(overlayBox), paragraph.paintBounds);
  }

  Rect _menuRect = Rect.zero;
  Size get _menuSize => Size(272, _actions.length > 4 ? 128 : 72);
  Set<MessageAction> get _actions => _fullSelection
      ? widget.session.fullActions
      : const {
          MessageAction.copy,
          MessageAction.selectAll,
          MessageAction.reply,
          MessageAction.forward,
        };

  @override
  void initState() {
    super.initState();
    _anchorEnd = widget.session.text.length;
    _fullSelection = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _menuRect = _computeMenuRect());
    });
  }

  void resetToFull() {
    setState(() {
      _anchorStart = 0;
      _anchorEnd = widget.session.text.length;
      _fullSelection = true;
      _menuRect = _computeMenuRect();
    });
  }

  (int, int) get _normalized {
    final start = _anchorStart.clamp(0, widget.session.text.length);
    final end = _anchorEnd.clamp(0, widget.session.text.length);
    return start <= end ? (start, end) : (end, start);
  }

  Rect _computeMenuRect() {
    final media = MediaQuery.of(context);
    final textBox = _textBox;
    final menuHeight = _menuSize.height + 14;
    final above = textBox.top - menuHeight >= media.padding.top + 8;
    final top = above
        ? textBox.top - menuHeight
        : (textBox.bottom + 8).clamp(
            media.padding.top, media.size.height - menuHeight - 8);
    final centerX = _selectionBounds().center.dx;
    final left = (centerX - _menuSize.width / 2)
        .clamp(8.0, media.size.width - _menuSize.width - 8);
    return Rect.fromLTWH(left, top, _menuSize.width, _menuSize.height);
  }

  Rect _selectionBounds() {
    final paragraph = _paragraph;
    final textBox = _textBox;
    final (start, end) = _normalized;
    if (paragraph == null || end <= start) return textBox;
    final boxes = paragraph.getBoxesForSelection(TextSelection(
        baseOffset: start, extentOffset: end, affinity: TextAffinity.downstream));
    if (boxes.isEmpty) return textBox;
    var rect = MatrixUtils.transformRect(
        paragraph.getTransformTo(_overlay.context.findRenderObject()),
        boxes.first.toRect());
    for (final box in boxes.skip(1)) {
      rect = rect.expandToInclude(MatrixUtils.transformRect(
          paragraph.getTransformTo(_overlay.context.findRenderObject()),
          box.toRect()));
    }
    return rect;
  }

  List<Rect> _selectionRects() {
    final paragraph = _paragraph;
    final (start, end) = _normalized;
    if (paragraph == null || end <= start) return const [];
    final overlayRender = _overlay.context.findRenderObject();
    return paragraph
        .getBoxesForSelection(TextSelection(
            baseOffset: start, extentOffset: end))
        .map((box) => MatrixUtils.transformRect(
            paragraph.getTransformTo(overlayRender), box.toRect()))
        .toList();
  }

  Rect? _caretRect(int offset, {required bool preferRightEdge}) {
    final paragraph = _paragraph;
    final length = widget.session.text.length;
    if (paragraph == null) return null;
    final overlayRender = _overlay.context.findRenderObject();
    Rect transformRect(Rect local) => MatrixUtils.transformRect(
        paragraph.getTransformTo(overlayRender), local);
    var boxes = paragraph.getBoxesForSelection(TextSelection(
        baseOffset: offset.clamp(0, length),
        extentOffset: offset.clamp(0, length)));
    if (boxes.isEmpty && offset > 0) {
      boxes = paragraph.getBoxesForSelection(TextSelection(
          baseOffset: offset - 1, extentOffset: offset));
      if (boxes.isNotEmpty) {
        final rect = transformRect(boxes.last.toRect());
        return preferRightEdge
            ? Rect.fromLTWH(rect.right, rect.top, 0, rect.height)
            : rect;
      }
    }
    if (boxes.isEmpty) return null;
    final rect = transformRect(boxes.last.toRect());
    return preferRightEdge
        ? Rect.fromLTWH(rect.right, rect.top, 0, rect.height)
        : Rect.fromLTWH(rect.left, rect.top, 0, rect.height);
  }

  void _setAnchor(_Handle handle, Offset global) {
    final paragraph = _paragraph;
    if (paragraph == null) return;
    final local = paragraph.globalToLocal(global);
    final position =
        paragraph.getPositionForOffset(local).offset.clamp(0, widget.session.text.length);
    setState(() {
      if (handle == _Handle.start) {
        _anchorStart = position;
      } else {
        _anchorEnd = position;
      }
      final (start, end) = _normalized;
      _fullSelection = start == 0 && end == widget.session.text.length;
      _menuRect = _computeMenuRect();
    });
  }

  void _cancel() => widget.session.dismiss();

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final (start, end) = _normalized;
    final rects = _selectionRects();
    final caretStart =
        _caretRect(start, preferRightEdge: false) ?? Rect.zero;
    final caretEnd = _caretRect(end, preferRightEdge: true) ?? Rect.zero;
    final dragging = _dragging != _Handle.none;
    final menuHidden = dragging || (_dragging != _Handle.none);
    return Stack(
      children: [
        // 半透明遮罩：点击空白取消；拖动/滚动穿透并触发取消（translucent）。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _cancel,
            onVerticalDragStart: (_) => _cancel(),
            child: const SizedBox.expand(),
          ),
        ),
        // 选区背景。
        for (final rect in rects)
          Positioned.fromRect(
            rect: rect,
            child: const DecoratedBox(
              decoration: BoxDecoration(color: Color(0x401AAD19)),
            ),
          ),
        // 起止手柄（左柄圆点在下、右柄圆点在上，微信样式）。
        _handle(
          caret: caretStart,
          preferRightEdge: false,
          handle: _Handle.start,
          dotAtBottom: true,
        ),
        _handle(
          caret: caretEnd,
          preferRightEdge: true,
          handle: _Handle.end,
          dotAtBottom: false,
        ),
        // 放大镜：拖动手柄时跟随手指所在文字位置，上移避让手指。
        if (dragging && _magnifierAnchor != null)
          Positioned(
            left: _magnifierAnchor!.dx - 60,
            top: _magnifierAnchor!.dy - 118,
            child: const CupertinoMagnifier(),
          ),
        // 长按菜单：拖动时淡出，松开恢复并按选框位置自适应。
        AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: menuHidden ? 0 : 1,
          child: Positioned.fromRect(
            rect: Rect.fromLTWH(
              _menuRect.left.clamp(8.0, media.size.width - 8 - _menuSize.width),
              _menuRect.top,
              _menuSize.width,
              _menuSize.height,
            ),
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
                  arrowAtTop: _menuRect.top < widget.session.messageRect.top,
                  arrowX: widget.session.messageRect.center.dx - _menuRect.left,
                  actions: _actions,
                  onSelected: (action) {
                    // “全选”恢复整条选择并保持菜单/选框打开。
                    if (action == MessageAction.selectAll) {
                      resetToFull();
                      return;
                    }
                    final (start, end) = _normalized;
                    final selected =
                        widget.session.text.substring(start, end);
                    widget.session.dismiss();
                    widget.session.onAction(
                      action,
                      _fullSelection ? null : selected,
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _handle({
    required Rect caret,
    required bool preferRightEdge,
    required _Handle handle,
    required bool dotAtBottom,
  }) {
    final x = preferRightEdge ? caret.right : caret.left;
    final active = _dragging == handle;
    return Positioned(
      left: x - 14,
      top: dotAtBottom ? caret.top - 4 : caret.top - caret.height - 14,
      width: 28,
      height: caret.height + 18,
      child: GestureDetector(
        key: Key('selection-handle-${handle.name}'),
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) {
          setState(() => _dragging = handle);
        },
        onPanUpdate: (details) {
          if (_dragging != handle) return;
          final global = details.globalPosition;
          _setAnchor(handle, global);
          final current = _normalized;
          final anchor = handle == _Handle.start ? current.$1 : current.$2;
          final caretNow =
              _caretRect(anchor, preferRightEdge: handle == _Handle.end);
          setState(() {
            _magnifierAnchor = caretNow == null
                ? null
                : Offset(
                    handle == _Handle.start ? caretNow.left : caretNow.right,
                    caretNow.top + caretNow.height / 2);
          });
        },
        onPanEnd: (_) => setState(() {
          _dragging = _Handle.none;
          _magnifierAnchor = null;
          _menuRect = _computeMenuRect();
        }),
        child: Center(
          child: SizedBox(
            width: 22,
            height: caret.height + 14,
            child: Column(
              children: [
                if (!dotAtBottom)
                  _handleDot(active: active, preferRightEdge: preferRightEdge),
                Expanded(
                  child: Align(
                    alignment: preferRightEdge
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      width: 2.5,
                      color: WeChatSelectionColor.resolve(context),
                    ),
                  ),
                ),
                if (dotAtBottom)
                  _handleDot(active: active, preferRightEdge: preferRightEdge),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _handleDot({required bool active, required bool preferRightEdge}) =>
      Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: WeChatSelectionColor.resolve(context),
          shape: BoxShape.circle,
          boxShadow: active
              ? const [
                  BoxShadow(color: Color(0x33000000), blurRadius: 4),
                ]
              : null,
        ),
      );
}

enum _Handle { none, start, end }

/// 微信选区/手柄颜色：亮色 #1AAD19 的浅色选区、暗色提高透明度。
final class WeChatSelectionColor {
  const WeChatSelectionColor._();

  static Color resolve(BuildContext context) =>
      CupertinoTheme.brightnessOf(context) == Brightness.dark
          ? const Color(0x661AAD19)
          : const Color(0x331AAD19);
}
