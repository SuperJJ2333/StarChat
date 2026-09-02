import '../../core/business_api_client.dart';
import 'chat_transfer_controller.dart';
import '../matrix/room_timeline_controller.dart';

final class BusinessChatTransferGateway
    implements ChatTransferBusinessGateway {
  const BusinessChatTransferGateway(this.api);
  final BusinessApiClient api;

  @override
  Future<Map<String, dynamic>> create(
          {required String receiverId,
          required String amount,
          String? note}) =>
      api.createChatTransfer(receiverId: receiverId, amount: amount, note: note);
}

final class TimelineChatTransferReferenceGateway
    implements ChatTransferReferenceGateway {
  const TimelineChatTransferReferenceGateway(this.timeline);
  final RoomTimelineController timeline;

  @override
  Future<void> sendReference(String transferId, String amount, String? note) =>
      timeline.sendTransferReference(transferId, amount, note);
}
