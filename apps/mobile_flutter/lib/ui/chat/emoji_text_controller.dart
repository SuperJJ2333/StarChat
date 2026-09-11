import 'package:flutter/cupertino.dart';

import 'emoji_text.dart';

/// 输入框控制器：文本内容、光标、选区与 IME composing 全部保持
/// [TextEditingController] 原生行为；仅重写 [buildTextSpan]，把表情目录内的
/// emoji 渲染为与消息气泡一致的彩色/动态字形，修复老系统字体缺字时
/// 输入框显示空白/方框的问题（例如 Android 9- 缺 🥲 等新字符）。
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

    addSegment(0, composing.start, isComposing: false);
    addSegment(composing.start, composing.end, isComposing: true);
    addSegment(composing.end, text.length, isComposing: false);
    return TextSpan(style: effectiveStyle, children: children);
  }
}
