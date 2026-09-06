import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/mention_composer_model.dart';

// Exact current room_page.dart:304-335 controller/model event order.
// Focused integration probe; not full RoomPage or device E2E.
void main() {
  test('827 selection-only move before trigger must cancel mention query', () {
    final model = MentionComposerModel();
    final input = TextEditingController();
    var last = '';
    input.addListener(() {
      final next = input.text;
      if (next != last) {
        final (start, removed, inserted) = MentionComposerModel.diffEdit(last, next);
        model.text = next;
        model.applyEdit(start: start, removed: removed, inserted: inserted);
        final cursor = input.selection.baseOffset;
        if (inserted > 0 && cursor > 0 && cursor <= next.length) {
          if (start + inserted == cursor && next.codeUnitAt(cursor - 1) == 0x40) {
            model.triggerAt(cursor - 1);
          }
        }
        final trigger = model.pendingTriggerStart;
        if (trigger != null && cursor >= 0) {
          final inQueryRange = cursor > trigger && cursor <= next.length;
          if (!inQueryRange) model.pendingTriggerStart = null;
        }
        last = next;
      }
    });
    input.value = const TextEditingValue(text: '@', selection: TextSelection.collapsed(offset: 1));
    input.value = const TextEditingValue(text: '@兄', selection: TextSelection.collapsed(offset: 2));
    expect(model.pendingTriggerStart, 0);
    input.selection = const TextSelection.collapsed(offset: 0);
    expect(model.pendingTriggerStart, isNull,
      reason: 'selection notification has unchanged text, so production range check is skipped');
    input.dispose();
  });
}
