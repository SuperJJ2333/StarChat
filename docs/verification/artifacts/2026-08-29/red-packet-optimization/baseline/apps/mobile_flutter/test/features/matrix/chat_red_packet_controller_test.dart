import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_red_packet_controller.dart';
import 'package:liuhetong_mobile/features/matrix/chat_red_packet_sheet.dart';

final class FakeRedPacketBusiness implements ChatRedPacketBusinessGateway {
  int creates = 0;
  String? recipientId;
  String? roomId;

  @override
  Future<String> create({
    required String mode,
    required String total,
    required int shareCount,
    String? roomId,
    String? recipientId,
  }) async {
    creates++;
    this.roomId = roomId;
    this.recipientId = recipientId;
    return 'packet-1';
  }
}

final class FakeRedPacketReference implements ChatRedPacketReferenceGateway {
  int sends = 0;
  bool fail = true;

  @override
  Future<void> sendReference(String packetId, String greeting) async {
    sends++;
    if (fail) throw Exception('matrix unavailable');
  }
}

void main() {
  test('share retry never creates a second authoritative red packet', () async {
    final business = FakeRedPacketBusiness();
    final references = FakeRedPacketReference();
    final controller = ChatRedPacketController(
      business: business,
      references: references,
      recipientId: 'user-bob',
    );

    await controller.submit(total: '8.88', greeting: '恭喜发财');
    expect(controller.state.status, ChatRedPacketStatus.shareFailed);
    expect(controller.state.packetId, 'packet-1');
    expect(business.creates, 1);
    expect(business.recipientId, 'user-bob');
    expect(business.roomId, isNull);

    references.fail = false;
    await controller.retryShare();

    expect(controller.state.status, ChatRedPacketStatus.sent);
    expect(business.creates, 1);
    expect(references.sends, 2);
  });

  testWidgets('direct chat red packet sheet creates and shares to the friend',
      (tester) async {
    final business = FakeRedPacketBusiness();
    final references = FakeRedPacketReference()..fail = false;
    final controller = ChatRedPacketController(
      business: business,
      references: references,
      recipientId: 'user-bob',
    );
    var sent = false;

    await tester.pumpWidget(
      CupertinoApp(
        home: ChatRedPacketSheet(
          controller: controller,
          isGroup: false,
          onSent: () => sent = true,
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('chat-red-packet-total')),
      '8.88',
    );
    await tester.enterText(
      find.byKey(const Key('chat-red-packet-greeting')),
      '恭喜发财',
    );
    await tester.tap(find.byKey(const Key('chat-red-packet-send')));
    await tester.pumpAndSettle();

    expect(sent, isTrue);
    expect(business.creates, 1);
    expect(find.text('红包已发送'), findsOneWidget);
  });
}
