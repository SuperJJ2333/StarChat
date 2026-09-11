import 'package:characters/characters.dart';

import '../../features/emoji/emoji_shortcode.dart';
import '../../features/emoji/fluent_emoji_catalog.dart';
import '../../features/emoji/fluent_vector_emoji_catalog.dart';

/// Converts the source UTF-16 offsets retained in Matrix messages to the
/// offsets exposed by [RenderParagraph]. Known emoji are [WidgetSpan]s and
/// therefore consume one render offset regardless of source UTF-16 length.
/// Existing `[shortcode]` text remains visually textual, but is selected as
/// one source token so a partial copy cannot split it.
final class MessageSelectionOffsetMapper {
  MessageSelectionOffsetMapper(this.source)
      : _segments = _buildSegments(source);

  final String source;
  final List<_OffsetSegment> _segments;

  int get renderLength => _segments.isEmpty ? 0 : _segments.last.renderEnd;

  /// Source boundaries that are safe for a selection handle. Catalog emoji
  /// graphemes and recognized `[shortcode]` tokens each contribute one atomic
  /// interval, so callers never trim a visual token to its final bracket.
  List<int> get sourceBoundaries => List<int>.unmodifiable([
        0,
        for (final segment in _segments) segment.sourceEnd,
      ]);

  (int, int) sourceRangeForRenderSelection(int baseOffset, int extentOffset) {
    final (rawStart, rawEnd) = baseOffset <= extentOffset
        ? (baseOffset, extentOffset)
        : (extentOffset, baseOffset);
    final start = _sourceBoundaryForRender(rawStart, start: true);
    final end = _sourceBoundaryForRender(rawEnd, start: false);
    return (start, end);
  }

  String selectedSourceForRenderSelection(int baseOffset, int extentOffset) {
    final (start, end) =
        sourceRangeForRenderSelection(baseOffset, extentOffset);
    return source.substring(start, end);
  }

  (int, int) renderSelectionForSourceRange(int baseOffset, int extentOffset) {
    final (rawStart, rawEnd) = baseOffset <= extentOffset
        ? (baseOffset, extentOffset)
        : (extentOffset, baseOffset);
    return (
      _renderBoundaryForSource(rawStart, start: true),
      _renderBoundaryForSource(rawEnd, start: false),
    );
  }

  int _sourceBoundaryForRender(int offset, {required bool start}) {
    final clamped = offset.clamp(0, renderLength).toInt();
    if (_segments.isEmpty) return 0;
    for (final segment in _segments) {
      if (clamped == segment.renderStart) {
        return segment.sourceStart;
      }
      if (clamped == segment.renderEnd) {
        return segment.sourceEnd;
      }
      if (clamped > segment.renderStart && clamped < segment.renderEnd) {
        if (segment.atomic) {
          return start ? segment.sourceStart : segment.sourceEnd;
        }
        return segment.sourceStart + (clamped - segment.renderStart);
      }
    }
    return source.length;
  }

  int _renderBoundaryForSource(int offset, {required bool start}) {
    final clamped = offset.clamp(0, source.length).toInt();
    if (_segments.isEmpty) return 0;
    for (final segment in _segments) {
      if (clamped == segment.sourceStart) {
        return segment.renderStart;
      }
      if (clamped == segment.sourceEnd) {
        return segment.renderEnd;
      }
      if (clamped > segment.sourceStart && clamped < segment.sourceEnd) {
        if (segment.atomic) {
          return start ? segment.renderStart : segment.renderEnd;
        }
        return segment.renderStart + (clamped - segment.sourceStart);
      }
    }
    return renderLength;
  }

  static List<_OffsetSegment> _buildSegments(String source) {
    final segments = <_OffsetSegment>[];
    var sourceOffset = 0;
    var renderOffset = 0;
    final shortcodeNames = emojiShortcodes.values.toSet();
    final shortcodePattern = RegExp(r'\[([^\[\]]+)\]');
    var cursor = 0;

    void add(String value, {required bool atomic, required bool widgetSpan}) {
      final sourceLength = value.length;
      final renderLength = widgetSpan ? 1 : sourceLength;
      segments.add(_OffsetSegment(
        sourceStart: sourceOffset,
        sourceEnd: sourceOffset + sourceLength,
        renderStart: renderOffset,
        renderEnd: renderOffset + renderLength,
        atomic: atomic || widgetSpan,
      ));
      sourceOffset += sourceLength;
      renderOffset += renderLength;
    }

    for (final match in shortcodePattern.allMatches(source)) {
      while (cursor < match.start) {
        final grapheme = source.substring(cursor).characters.first;
        add(grapheme, atomic: true, widgetSpan: _isWidgetSpan(grapheme));
        cursor += grapheme.length;
      }
      final token = match.group(0)!;
      final name = match.group(1)!;
      if (shortcodeNames.contains(name)) {
        add(token, atomic: true, widgetSpan: false);
      } else {
        for (final grapheme in token.characters) {
          add(grapheme, atomic: true, widgetSpan: _isWidgetSpan(grapheme));
        }
      }
      cursor = match.end;
    }
    while (cursor < source.length) {
      final grapheme = source.substring(cursor).characters.first;
      add(grapheme, atomic: true, widgetSpan: _isWidgetSpan(grapheme));
      cursor += grapheme.length;
    }
    return segments;
  }

  static bool _isWidgetSpan(String grapheme) =>
      fluentEmojiByChar(grapheme) != null ||
      vectorEmojiByChar(grapheme) != null;
}

final class _OffsetSegment {
  const _OffsetSegment({
    required this.sourceStart,
    required this.sourceEnd,
    required this.renderStart,
    required this.renderEnd,
    required this.atomic,
  });

  final int sourceStart;
  final int sourceEnd;
  final int renderStart;
  final int renderEnd;
  final bool atomic;
}
