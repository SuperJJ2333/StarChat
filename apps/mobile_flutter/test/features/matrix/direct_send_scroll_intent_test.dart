import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/ui/chat/latest_message_anchor.dart';
import 'room_timeline_controller_test.dart' show FakeTimelineAdapter;

class _HeldReferences extends FakeTimelineAdapter {
  final gate = Completer<String>();
  @override
  Future<String> sendRedPacketReference(String packetId, String greeting,
          {String? mode, String? recipientId, String? recipientMatrixId}) =>
      gate.future;
  @override
  Future<String> sendTransferReference(
          String transferId, String amount, String? note,
          {String? receiverId, String? receiverMatrixId}) =>
      gate.future;
}

void main() {
  for (final kind in ['video', 'packet', 'transfer']) {
    testWidgets(
        'explicit $kind send follows once; waiting completion preserves new reading position',
        (tester) async {
      final adapter = _HeldReferences();
      final timeline = RoomTimelineController(adapter);
      final scroll = ScrollController(initialScrollOffset: 150);
      final anchor = LatestMessageAnchor(scroll);
      timeline.addListener(() => anchor.update(timeline.latestLocalSendIntent,
          outgoing: true, newSend: true));
      await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: ListView.builder(
              controller: scroll,
              reverse: true,
              itemCount: 30,
              itemBuilder: (_, index) =>
                  SizedBox(height: 70, child: Text('$index')))));
      late Future<String> pending;
      if (kind == 'video') {
        timeline.beginLocalSend();
        pending = adapter.gate.future;
      } else if (kind == 'packet') {
        pending = timeline.sendRedPacketReference('synthetic', 'synthetic');
      } else {
        pending = timeline.sendTransferReference('synthetic', '1.00', null);
      }
      await tester.pump();
      expect(scroll.offset, 0);
      anchor.cancelPending();
      scroll.jumpTo(210);
      adapter.gate.complete('synthetic-event');
      await pending;
      await timeline.refresh();
      await tester.pump();
      expect(scroll.offset, 210);
      anchor.dispose();
      timeline.dispose();
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    });
  }
}
