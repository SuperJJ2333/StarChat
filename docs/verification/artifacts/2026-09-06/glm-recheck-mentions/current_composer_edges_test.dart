import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/mention_composer_model.dart';

// Current production ordering from room_page.dart:279-310, 746-763.
// This is a focused controller/model probe, not a RoomPage widget E2E.
void main() {
  test('sending literal unselected @ query clears trigger as well as text', () {
    final model = MentionComposerModel()..text = '@兄';
    model.triggerAt(0);
    final input = TextEditingController(text: '@兄');
    var last = '@兄';
    var guard = false;
    input.addListener(() {
      if (guard) return;
      final next = input.text;
      if (next != last) {
        final (start, removed, inserted) = MentionComposerModel.diffEdit(last, next);
        model.text = next;
        model.applyEdit(start: start, removed: removed, inserted: inserted);
        final cursor = input.selection.baseOffset;
        if (inserted > 0 && cursor > 0 && cursor <= next.length &&
            start + inserted == cursor && next.codeUnitAt(cursor - 1) == 0x40) {
          model.triggerAt(cursor - 1);
        }
        last = next;
      }
    });
    // Same clear body as current _send; guard suppresses applyEdit cleanup.
    guard = true;
    input.clear();
    last = '';
    model..text = ''..tokens.clear();
    guard = false;
    input.value = const TextEditingValue(text: '你好', selection: TextSelection.collapsed(offset: 2));
    expect(model.pendingTriggerStart, isNull,
      reason: 'new ordinary draft must not reopen mention panel with stale trigger');
    input.dispose();
  });
  test('moving caret before trigger cancels active query', () {
    final model = MentionComposerModel()..text = '@兄';
    model.triggerAt(0);
    final input = TextEditingController.fromValue(const TextEditingValue(
      text: '@兄', selection: TextSelection.collapsed(offset: 2)));
    var last = input.text;
    input.addListener(() {
      final next = input.text;
      if (next != last) {
        final (start, removed, inserted) = MentionComposerModel.diffEdit(last, next);
        model.text = next;
        model.applyEdit(start: start, removed: removed, inserted: inserted);
        last = next;
      }
      // Production checks only pendingTriggerStart != null, no caret validation.
    });
    input.selection = const TextSelection.collapsed(offset: 0);
    expect(model.pendingTriggerStart, isNull,
      reason: 'otherwise selecting Bob produces @Bob @兄 instead of cancelling old query');
    input.dispose();
  });
}
