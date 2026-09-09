import '../../core/business_api_client.dart';
import '../../core/chat_payment_intent.dart';
import 'chat_red_packet_controller.dart';
import 'room_timeline_controller.dart';

final class BusinessChatRedPacketGateway
    implements ChatRedPacketBusinessGateway {
  const BusinessChatRedPacketGateway(this.api, {required this.payment});

  final BusinessApiClient api;
  final ChatPaymentIntent payment;

  @override
  Future<String> create({
    required String mode,
    required String total,
    required int shareCount,
    String? roomId,
    String? recipientId,
  }) async =>
      (await payment.create('red_packet.create', {
        'mode': mode,
        'total': total,
        'share_count': shareCount,
        if (roomId != null) 'room_id': roomId,
        if (recipientId != null) 'recipient_id': recipientId,
      }))['id'] as String;
}

final class TimelineRedPacketReferenceGateway
    implements ChatRedPacketReferenceGateway {
  const TimelineRedPacketReferenceGateway(this.timeline);

  final RoomTimelineController timeline;

  @override
  Future<void> sendReference(String packetId, String greeting) async {
    await timeline.sendRedPacketReference(packetId, greeting);
  }
}
