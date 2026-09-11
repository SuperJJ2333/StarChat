import 'package:flutter/cupertino.dart';

import 'emoji_text.dart';

/// 输入框控制器：文本内容、光标、选区与 IME composing 全部保持
/// [TextEditingController] 原生行为；仅重写 [buildTextSpan]，把表情目录内的
/// emoji 渲染为与消息气泡一致的彩色/动态字形，修复老系统字体缺字时
/// 输入框显示空白/方框的问题（例如 Android 9- 缺 🥲 等新字符）。
///
/// 光标/选区/composing 一律吸附到**字素（grapheme）边界**：光标永远不会
/// 停在 emoji 字素中间，因此前方有（动态）emoji 时新输入的文字不会"钻进"
/// emoji 内部，也不会把代理对切成两半造成乱码。
///
/// 已知取舍：composing（拼音候选下划线）区域内若混排 emoji，下划线只覆盖
/// 其中的文字片段；emoji 字形本身不带下划线，不影响组词与上屏。
final class EmojiEditingController extends TextEditingController {
  EmojiEditingController({super.text});

  static final TextStyle _composingUnderline = const TextStyle(
    decoration: TextDecoration.underline,
    decorationStyle: TextDecorationStyle.dotted,
    decorationThickness: 1.5,
  );

  static List<int> _graphemeBoundariesOf(String text) {
    final boundaries = <int>[0];
    for (final grapheme in text.characters) {
      boundaries.add(boundaries.last + grapheme.length);
    }
    return boundaries;
  }

  static int _floorBoundary(List<int> boundaries, int value) {
    for (var i = boundaries.length - 1; i >= 0; i--) {
      if (boundaries[i] <= value) return boundaries[i];
    }
    return 0;
  }

  static int _ceilBoundary(List<int> boundaries, int value) {
    for (final bound in boundaries) {
      if (bound >= value) return bound;
    }
    return value;
  }

  /// 距离最近的字素边界（平手取前边界）：把落在 emoji/组合字素内部
  /// 的偏移拉回安全边界。
  static int _nearestBoundary(List<int> boundaries, int value) {
    if (value <= 0 || value >= boundaries.last) return value;
    final floor = _floorBoundary(boundaries, value);
    final ceil = _ceilBoundary(boundaries, value);
    return (value - floor) <= (ceil - value) ? floor : ceil;
  }

  /// 用户敲键/点击/长按选区后，光标可能落在 UTF-16 字素中间（尤其
  /// 文字前方有动态 emoji 时）。在值写入前把 base/extent/composing
  /// 吸附到字素边界，杜绝"新文字钻进 emoji"与乱码。
  @override
  set value(TextEditingValue newValue) {
    if (newValue.text.isEmpty || identical(newValue, value)) {
      super.value = newValue;
      return;
    }
    final boundaries = _graphemeBoundariesOf(newValue.text);
    var selection = newValue.selection;
    if (selection.isValid) {
      final base = _nearestBoundary(boundaries, selection.baseOffset);
      final extent = _nearestBoundary(boundaries, selection.extentOffset);
      if (base != selection.baseOffset || extent != selection.extentOffset) {
        selection = TextSelection(
          baseOffset: base,
          extentOffset: extent,
          affinity: selection.affinity,
          isDirectional: selection.isDirectional,
        );
      }
    }
    var composing = newValue.composing;
    if (composing.isValid && !composing.isCollapsed) {
      final start = _floorBoundary(boundaries, composing.start);
      final end = _ceilBoundary(boundaries, composing.end)
          .clamp(start, newValue.text.length);
      if (start != composing.start || end != composing.end) {
        composing = TextRange(start: start, end: end);
      }
    }
    super.value = newValue.copyWith(selection: selection, composing: composing);
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final effectiveStyle = style ?? const TextStyle(fontSize: 16);
    final composing = value.composing;
    if (!withComposing || !composing.isValid || composing.isCollapsed) {
      final spans =
          buildEmojiInlineSpans(text, fontSize: effectiveStyle.fontSize ?? 16);
      if (spans == null) {
        return TextSpan(style: effectiveStyle, text: text);
      }
      return TextSpan(style: effectiveStyle, children: spans);
    }
    // 字素边界对齐：composing 区间按完整字素外扩，绝不把 emoji/
    // 代理对切成两半（否则会出现乱码）。
    final boundaries = _graphemeBoundariesOf(text);
    final composingStart = _floorBoundary(boundaries, composing.start);
    final composingEnd = _ceilBoundary(boundaries, composing.end)
        .clamp(composingStart, text.length);
    final children = <InlineSpan>[];
    void addSegment(int start, int end, {required bool isComposing}) {
      if (end <= start) return;
      final segment = text.substring(start, end);
      final spans =
          buildEmojiInlineSpans(segment, fontSize: effectiveStyle.fontSize ?? 16);
      if (spans == null) {
        children.add(TextSpan(
            text: segment,
            style: isComposing
                ? effectiveStyle.merge(_composingUnderline)
                : null));
      } else if (isComposing) {
        children.add(TextSpan(
            style: effectiveStyle.merge(_composingUnderline), children: spans));
      } else {
        children.addAll(spans);
      }
    }

    addSegment(0, composingStart, isComposing: false);
    addSegment(composingStart, composingEnd, isComposing: true);
    addSegment(composingEnd, text.length, isComposing: false);
    return TextSpan(style: effectiveStyle, children: children);
  }
}
