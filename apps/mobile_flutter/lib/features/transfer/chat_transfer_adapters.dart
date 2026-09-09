import '../../core/business_api_client.dart';
import '../../core/chat_payment_intent.dart';
import 'chat_transfer_controller.dart';
import '../matrix/room_timeline_controller.dart';

final class BusinessChatTransferGateway implements ChatTransferBusinessGateway {
  const BusinessChatTransferGateway(this.api, {required this.payment});
  final BusinessApiClient api;
  final ChatPaymentIntent payment;

  @override
  Future<Map<String, dynamic>> create(
          {required String receiverId, required String amount, String? note}) =>
      payment.create('chat_transfer.create', {
        'receiver_id': receiverId,
        'amount': amount,
        if (note != null && note.isNotEmpty) 'note': note,
      });
}

final class TimelineChatTransferReferenceGateway
    implements ChatTransferReferenceGateway {
  const TimelineChatTransferReferenceGateway(this.timeline);
  final RoomTimelineController timeline;

  @override
  Future<void> sendReference(String transferId, String amount, String? note) =>
      timeline.sendTransferReference(transferId, amount, note);
}
