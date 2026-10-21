import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'logical_conversation_timeline_test.dart' show WindowSource;
import 'automatic_retry_order_test.dart' show syntheticOutbox;

class _WindowAdapter extends WindowSource implements RoomTimelineAdapter {}

void main() {
  for (final restoreOnly in [false, true]) {
    test('recovered outbox preserves older selected window: $restoreOnly',
        () async {
      final source = _WindowAdapter();
      final controller = RoomTimelineController(source,
          windowed: true, canDispatchNow: () => false);
      addTearDown(controller.dispose);
      await controller.showEarlierWindow();
      await controller.showEarlierWindow();
      expect(controller.hasLaterWindow, isTrue);
      final before = controller.messages.map((m) => m.stableId).toList();
      final row = syntheticOutbox();
      if (restoreOnly) {
        controller.restoreOutboxMessage(row);
      } else {
        await controller.sendText(row.content, outboxRow: row);
      }
      expect(controller.hasLaterWindow, isTrue);
      expect(controller.messages.map((m) => m.stableId), before);
      expect(controller.latestLocalSendIntent, isNull);
    });
  }
}
