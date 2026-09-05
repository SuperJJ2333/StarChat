import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/message_action.dart';

void main() {
  test('multi-select starts with the pressed message and toggles stably', () {
    final selection = MessageSelectionController()..startWith(r'$one');

    selection.toggle(r'$two');
    selection.toggle(r'$one');

    expect(selection.active, isTrue);
    expect(selection.selectedIds, {r'$two'});
  });

  test('exit clears selection and batch forward rejects unsafe messages', () {
    final selection = MessageSelectionController()
      ..startWith(r'$packet')
      ..toggle(r'$text');

    expect(
      selection.canForward((id) => id != r'$packet'),
      isFalse,
    );

    selection.exit();
    expect(selection.active, isFalse);
    expect(selection.selectedIds, isEmpty);
  });
}
