import 'package:flutter/cupertino.dart';

import '../../features/emoji/fluent_emoji_catalog.dart';
import '../../features/emoji/fluent_vector_emoji_catalog.dart';

/// A controller for a chat input that may be decorated with dynamic emoji.
///
/// While attached to an emoji overlay, catalog emoji remain their original
/// UTF-16 source text in RenderEditable and are merely transparent; the visual
/// glyph is painted by WeChatEmojiInputDecoration. This keeps IME composing,
/// undo, selections and caret offsets in Flutter's native text coordinate
/// system. A bare controller delegates to Flutter's native text span so no
/// caller can accidentally reintroduce compressed WidgetSpan offsets.
final class EmojiEditingController extends TextEditingController {
  EmojiEditingController({super.text});

  var _emojiOverlayAttachments = 0;
  var _disposed = false;

  void attachEmojiOverlay() {
    if (_disposed) return;
    _emojiOverlayAttachments++;
    if (_emojiOverlayAttachments != 1) return;
    notifyListeners();
  }

  void detachEmojiOverlay() {
    if (_emojiOverlayAttachments == 0) return;
    _emojiOverlayAttachments--;
    if (_disposed || _emojiOverlayAttachments != 0) return;
    notifyListeners();
  }

  static bool isCatalogEmoji(String grapheme) =>
      fluentEmojiByChar(grapheme) != null ||
      vectorEmojiByChar(grapheme) != null;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final effectiveStyle = style ?? const TextStyle(fontSize: 16);
    if (_emojiOverlayAttachments == 0 || !text.characters.any(isCatalogEmoji)) {
      return super.buildTextSpan(
        context: context,
        style: effectiveStyle,
        withComposing: withComposing,
      );
    }

    final composing = value.composing;
    final children = <InlineSpan>[];
    var offset = 0;
    for (final grapheme in text.characters) {
      final end = offset + grapheme.length;
      final isComposing = withComposing &&
          composing.isValid &&
          !composing.isCollapsed &&
          offset < composing.end &&
          end > composing.start;
      final glyphStyle = isCatalogEmoji(grapheme)
          ? effectiveStyle.copyWith(color: CupertinoColors.transparent)
          : effectiveStyle;
      children.add(TextSpan(
        text: grapheme,
        style: isComposing
            ? glyphStyle.copyWith(
                decoration: TextDecoration.underline,
                decorationStyle: TextDecorationStyle.dotted,
                decorationThickness: 1.5,
              )
            : glyphStyle,
      ));
      offset = end;
    }
    return TextSpan(style: effectiveStyle, children: children);
  }
}
