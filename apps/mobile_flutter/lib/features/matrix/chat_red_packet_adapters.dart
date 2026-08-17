import '../../core/business_api_client.dart';
import 'chat_red_packet_controller.dart';
import 'room_timeline_controller.dart';

final class BusinessChatRedPacketGateway
    implements ChatRedPacketBusinessGateway {
  const BusinessChatRedPacketGateway(this.api);

  final BusinessApiClient api;

  @override
  Future<String> create({
    required String mode,
    required String total,
    required int shareCount,
    String? roomId,
    String? recipientId,
  }) async =>
      (await api.createRedPacket(
        mode: mode,
        total: total,
        shareCount: shareCount,
        roomId: roomId,
        recipientId: recipientId,
      ))['id'] as String;
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
