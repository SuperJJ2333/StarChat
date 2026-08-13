import 'package:matrix/matrix.dart';

import 'room_timeline_controller.dart';

final class MatrixRoomTimelineAdapter implements RoomTimelineAdapter {
  MatrixRoomTimelineAdapter(this.room, this.timeline);
  final Room room;
  final Timeline timeline;

  @override
  List<RoomMessageViewModel> snapshot() => timeline.events.reversed.map((event) {
    final status = event.status.isError
        ? RoomDeliveryState.failed
        : event.status.isSending
            ? RoomDeliveryState.sending
            : RoomDeliveryState.sent;
    return RoomMessageViewModel(
      id: event.eventId,
      senderId: event.senderId,
      text: event.redacted ? '消息已撤回' : event.text,
      isOwn: event.senderId == room.client.userID,
      deliveryState: status,
    );
  }).toList(growable: false);

  @override
  Future<String> sendText(String text) async =>
      await room.sendTextEvent(text, parseCommands: false) ?? (throw StateError('消息发送失败'));

  @override
  Future<void> retry(String transactionId) async {
    throw UnsupportedError('请重新发送失败消息');
  }

  @override
  Future<void> loadHistory() => timeline.requestHistory();

  @override
  Future<void> markRead() => timeline.setReadMarker();

  @override
  void dispose() => timeline.cancelSubscriptions();
}
