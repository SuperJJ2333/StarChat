import 'dart:typed_data';

import 'package:matrix/matrix.dart';

import 'room_timeline_controller.dart';
import 'nudge_service.dart';

const changliaoRedPacketMessageType = 'com.changliao.red_packet';

final class MatrixRoomTimelineAdapter implements RoomTimelineAdapter {
  MatrixRoomTimelineAdapter(this.room, this.timeline);

  final Room room;
  final Timeline timeline;

  @override
  List<RoomMessageViewModel> snapshot() => timeline.events
      .where(
        (event) =>
            event.type == EventTypes.Message ||
            event.type == changliaoNudgeEventType,
      )
      .toList(growable: false)
      .reversed
      .map(_message)
      .toList(growable: false);

  RoomMessageViewModel _message(Event event) {
    final status = event.status.isError
        ? RoomDeliveryState.failed
        : event.status.isSending
            ? RoomDeliveryState.sending
            : RoomDeliveryState.sent;
    final messageType = event.messageType;
    final info = event.content['info'];
    final durationMilliseconds =
        info is Map ? int.tryParse(info['duration']?.toString() ?? '') : null;
    final mimeType = info is Map ? info['mimetype']?.toString() : null;
    final nudge = event.type == changliaoNudgeEventType;
    final nudgeText = nudge
        ? '${event.content['sender_display_name'] ?? '好友'}拍了拍'
            '${event.content['target_display_name'] ?? '好友'}'
            '${event.content['suffix'] ?? ''}'
        : null;
    return RoomMessageViewModel(
      id: event.eventId,
      senderId: event.senderId,
      text: event.redacted ? '' : (nudgeText ?? event.text),
      isOwn: event.senderId == room.client.userID,
      deliveryState: status,
      timestamp: event.originServerTs.toLocal(),
      kind: nudge
          ? RoomMessageKind.system
          : switch (messageType) {
              MessageTypes.Image => RoomMessageKind.image,
              MessageTypes.Audio => RoomMessageKind.voice,
              MessageTypes.File => RoomMessageKind.file,
              changliaoRedPacketMessageType => RoomMessageKind.redPacket,
              _ => RoomMessageKind.text,
            },
      mimeType: mimeType,
      packetId: event.content['packet_id']?.toString(),
      greeting: event.content['greeting']?.toString(),
      voiceDuration: Duration(milliseconds: durationMilliseconds ?? 1000),
      isRecalled: event.redacted,
      replyToEventId: ((event.content['m.relates_to'] as Map?)?['m.in_reply_to']
              as Map?)?['event_id']
          ?.toString(),
    );
  }

  @override
  Future<String> sendText(String text) async =>
      await room.sendTextEvent(text, parseCommands: false) ??
      (throw StateError('消息发送失败'));

  @override
  Future<String> sendRedPacketReference(
    String packetId,
    String greeting,
  ) async =>
      await room.sendEvent({
        'msgtype': changliaoRedPacketMessageType,
        'body': '[畅聊彩币红包]',
        'packet_id': packetId,
        'greeting': greeting,
      }) ??
      (throw StateError('红包消息发送失败'));

  @override
  Future<Uint8List> loadAttachment(String eventId) async {
    final event = timeline.events.firstWhere(
      (candidate) => candidate.eventId == eventId,
    );
    return (await event.downloadAndDecryptAttachment()).bytes;
  }

  @override
  Future<void> retry(String transactionId) async {
    final event = timeline.events.firstWhere(
      (candidate) => candidate.eventId == transactionId,
    );
    await event.sendAgain();
  }

  @override
  Future<void> loadHistory() => timeline.requestHistory();

  @override
  Future<void> markRead() => timeline.setReadMarker();

  @override
  void dispose() => timeline.cancelSubscriptions();
}
