import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/mention_composer_model.dart';

// Exact ordering of RoomPage composer listener and mutation paths.
class Harness {
  final input = TextEditingController();
  final model = MentionComposerModel();
  String last = '';
  Harness() { input.addListener(changed); }
  void changed() {
    final next = input.text;
    if (next != last) {
      final (start, removed, inserted) = MentionComposerModel.diffEdit(last, next);
      model.applyEdit(start: start, removed: removed, inserted: inserted);
      final cursor = input.selection.baseOffset;
      if (inserted > 0 && cursor > 0 && cursor <= next.length) {
        final insertedEnd = start + inserted;
        if (insertedEnd == cursor && next.codeUnitAt(cursor - 1) == 0x40) {
          model.triggerAt(cursor - 1);
        }
      }
      model.text = next;
      last = next;
    }
  }
}
void main() {
  test('real listener typing @ opens mention trigger', () {
    final h = Harness();
    h.input.value = const TextEditingValue(text: '@', selection: TextSelection.collapsed(offset: 1));
    expect(h.model.pendingTriggerStart, 0);
  });
  test('programmatic avatar mention retains recipient', () {
    final h = Harness();
    final caret = h.model.appendAtEnd(displayName: '兄弟', userId: '@brother:test');
    h.input..text = h.model.text..selection = TextSelection.collapsed(offset: caret);
    h.last = h.model.text;
    expect(h.model.recipientUserIds(), ['@brother:test']);
  });
  test('send snapshots recipients before clearing text', () {
    final h = Harness();
    h.input.value = const TextEditingValue(text: '@兄弟 ', selection: TextSelection.collapsed(offset: 4));
    h.model.tokens.add(MentionToken(start: 0, end: 3, display: '兄弟', userId: '@brother:test'));
    expect(h.model.recipientUserIds(), ['@brother:test']);
    h.input.clear(); // room_page.dart:726
    final ids = h.model.recipientUserIds(); // room_page.dart:731
    expect(ids, ['@brother:test']);
  });
}
