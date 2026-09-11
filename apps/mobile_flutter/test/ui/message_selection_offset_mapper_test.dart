import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/message_selection_offset_mapper.dart';

void main() {
  test('maps WidgetSpan emoji render offsets to complete source graphemes', () {
    final mapper = MessageSelectionOffsetMapper('甲🥲乙❤️丙');

    // Each catalog emoji is one RenderParagraph placeholder, even where the
    // original grapheme spans multiple UTF-16 code units.
    expect(mapper.renderLength, 5);
    expect(mapper.selectedSourceForRenderSelection(1, 2), '🥲');
    expect(mapper.selectedSourceForRenderSelection(2, 3), '乙');
    expect(mapper.selectedSourceForRenderSelection(3, 4), '❤️');
    expect(mapper.selectedSourceForRenderSelection(1, 4), '🥲乙❤️');
  });

  test('preserves exact boundaries around adjacent emoji placeholders', () {
    final mapper = MessageSelectionOffsetMapper('🥲🥲中文');

    expect(mapper.sourceRangeForRenderSelection(0, 0), const (0, 0));
    expect(mapper.sourceRangeForRenderSelection(1, 1), const (2, 2));
    expect(mapper.selectedSourceForRenderSelection(0, 1), '🥲');
    expect(mapper.selectedSourceForRenderSelection(1, 2), '🥲');
    expect(mapper.selectedSourceForRenderSelection(1, 3), '🥲中');
  });

  test('rounds a render offset inside an atomic shortcode to its source range',
      () {
    final mapper = MessageSelectionOffsetMapper('a[微笑]b');

    expect(mapper.renderLength, 6);
    expect(mapper.selectedSourceForRenderSelection(1, 5), '[微笑]');
    expect(mapper.renderSelectionForSourceRange(1, 5), const (1, 5));
    expect(mapper.sourceBoundaries, [0, 1, 5, 6]);
  });

  test('keeps ordinary UTF-16 text offsets exact', () {
    final mapper = MessageSelectionOffsetMapper('hello\n世界');

    expect(mapper.renderLength, 'hello\n世界'.length);
    expect(mapper.selectedSourceForRenderSelection(1, 6), 'ello\n');
  });

  test('keeps an unknown bracket token aligned with its rendered emoji', () {
    final mapper = MessageSelectionOffsetMapper('[🥲x]');

    expect(mapper.renderLength, 4);
    expect(mapper.selectedSourceForRenderSelection(1, 2), '🥲');
  });
}
