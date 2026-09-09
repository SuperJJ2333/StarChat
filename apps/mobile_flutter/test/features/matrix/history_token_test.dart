import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'room_timeline_controller_test.dart' show FakeTimelineAdapter;

class TokenAdapter extends FakeTimelineAdapter implements RoomHistoryStatus {
  @override
  bool canLoadHistory = true;
}

void main() {
  test('state-only page does not mark real Matrix history exhausted', () async {
    final adapter = TokenAdapter()..historyPages = 0;
    final controller = RoomTimelineController(adapter);
    await controller.loadHistory();
    expect(controller.historyExhausted, isFalse);
    adapter.historyPages = 1;
    await controller.loadHistory();
    expect(controller.messages, hasLength(1));
    adapter.canLoadHistory = false;
    await controller.loadHistory();
    expect(controller.historyExhausted, isTrue);
    controller.dispose();
  });
}
