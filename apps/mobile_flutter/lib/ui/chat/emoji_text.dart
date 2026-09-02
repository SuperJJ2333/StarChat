import 'package:flutter/cupertino.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../features/emoji/fluent_emoji_catalog.dart';
import '../../features/emoji/fluent_vector_emoji_catalog.dart';

/// 内联 emoji 字形相对字号的比例，使矢量字形与系统文本字高视觉对齐。
const _kEmojiGlyphSizeFactor = 1.18;

/// 动态字形（Animated Fluent WebP）：文本流中持续播放动画，
/// 混排（文字+emoji）场景不再退化为静态图。
final class EmojiAnimatedGlyph extends StatelessWidget {
  const EmojiAnimatedGlyph({super.key, required this.asset, required this.size});

  final String asset;
  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
        asset,
        width: size,
        height: size,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        filterQuality: FilterQuality.high,
      );
}

/// fluentui-emoji 矢量字形：按 widget 尺寸 × DPR 栅格化，任意分辨率下锐利。
final class EmojiVectorGlyph extends StatelessWidget {
  const EmojiVectorGlyph({super.key, required this.asset, required this.size});

  final String asset;
  final double size;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
        asset,
        width: size,
        height: size,
        fit: BoxFit.contain,
      );
}

/// 按字素切分文本，已知 emoji 生成矢量 WidgetSpan。
/// 返回 null 表示文本不含矢量 emoji，调用方可走 [Text] 快速路径。
List<InlineSpan>? buildEmojiInlineSpans(String text, {double fontSize = 16}) {
  List<InlineSpan>? spans;
  final plain = StringBuffer();

  void flushPlain() {
    if (plain.isEmpty) return;
    (spans ??= <InlineSpan>[]).add(TextSpan(text: plain.toString()));
    plain.clear();
  }

  for (final grapheme in text.characters) {
    // 动态库优先：混排场景保持动画播放；未收录再回退矢量静态字形。
    final animated = fluentEmojiByChar(grapheme);
    if (animated != null) {
      flushPlain();
      (spans ??= <InlineSpan>[]).add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: EmojiAnimatedGlyph(
            asset: animated.asset,
            size: fontSize * _kEmojiGlyphSizeFactor,
          ),
        ),
      );
      continue;
    }
    final emoji = vectorEmojiByChar(grapheme);
    if (emoji == null) {
      plain.write(grapheme);
      continue;
    }
    flushPlain();
    (spans ??= <InlineSpan>[]).add(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: EmojiVectorGlyph(
          asset: emoji.asset,
          size: fontSize * _kEmojiGlyphSizeFactor,
        ),
      ),
    );
  }
  if (spans == null) return null;
  flushPlain();
  return spans;
}

/// 消息文本渲染：目录内 emoji 使用 fluentui-emoji 矢量字形（高 DPI 清晰锐利），
/// 目录外字符与普通文本保持系统渲染，不丢字符、不改变消息内容。
final class EmojiText extends StatelessWidget {
  const EmojiText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = style ?? DefaultTextStyle.of(context).style;
    final spans = buildEmojiInlineSpans(
      text,
      fontSize: effectiveStyle.fontSize ?? 16,
    );
    if (spans == null) {
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      );
    }
    return Text.rich(
      TextSpan(text: '', style: style, children: spans),
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
  }
}
