import 'dart:typed_data';

import 'package:matrix/matrix.dart';

import 'room_timeline_controller.dart';
import 'nudge_service.dart';

const changliaoRedPacketMessageType = 'com.changliao.red_packet';

/// 通话结束摘要消息：由呼叫方在通话结束时发送，双端会话各显示一条
/// “通话时长/已取消”行。
const changliaoCallMessageType = 'com.changliao.call';
const changliaoTransferMessageType = 'com.changliao.transfer';

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
    final attachmentSize =
        info is Map ? int.tryParse(info['size']?.toString() ?? '') : null;
    final nudge = event.type == changliaoNudgeEventType;
    final nudgeInfo = nudge
        ? NudgeInfo(
            senderId: event.content['sender_id']?.toString() ?? event.senderId,
            senderName: event.content['sender_display_name']?.toString() ?? '好友',
            targetUserId: event.content['target_user_id']?.toString() ?? '',
            targetName: event.content['target_display_name']?.toString() ?? '好友',
            suffix: event.content['suffix']?.toString() ?? '',
          )
        : null;
    return RoomMessageViewModel(
      id: event.eventId,
      senderId: event.senderId,
      text: event.redacted ? '' : (nudge ? '' : event.text),
      isOwn: event.senderId == room.client.userID,
      deliveryState: status,
      timestamp: event.originServerTs.toLocal(),
      kind: nudge
          ? RoomMessageKind.system
          : switch (messageType) {
              MessageTypes.Image => RoomMessageKind.image,
              MessageTypes.Video => RoomMessageKind.video,
              MessageTypes.Audio => RoomMessageKind.voice,
              MessageTypes.File => RoomMessageKind.file,
              changliaoRedPacketMessageType => RoomMessageKind.redPacket,
              changliaoCallMessageType => RoomMessageKind.call,
              changliaoTransferMessageType => RoomMessageKind.transfer,
              _ => RoomMessageKind.text,
            },
      mimeType: mimeType,
      attachmentSize: attachmentSize,
      packetId: event.content['packet_id']?.toString(),
      greeting: event.content['greeting']?.toString(),
      transferId: event.content['transfer_id']?.toString(),
      transferAmount: event.content['transfer_amount']?.toString(),
      transferNote: event.content['transfer_note']?.toString(),
      voiceDuration: Duration(milliseconds: durationMilliseconds ?? 1000),
      videoDuration: messageType == MessageTypes.Video
          ? Duration(
              milliseconds: info is Map
                  ? int.tryParse(info['duration']?.toString() ?? '') ?? 0
                  : 0)
          : null,
      callVideo: messageType == changliaoCallMessageType &&
          event.content['call_type']?.toString() == 'video',
      callConnected: messageType == changliaoCallMessageType &&
          event.content['call_connected']?.toString() == 'true',
      callDuration: Duration(
          milliseconds: messageType == changliaoCallMessageType
              ? int.tryParse(
                      event.content['duration_ms']?.toString() ?? '') ??
                  0
              : 0),
      isRecalled: event.redacted,
      replyToEventId: ((event.content['m.relates_to'] as Map?)?['m.in_reply_to']
              as Map?)?['event_id']
          ?.toString(),
      nudge: nudgeInfo,
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
        'body': '[畅聊点钻红包]',
        'packet_id': packetId,
        'greeting': greeting,
      }) ??
      (throw StateError('红包消息发送失败'));

  @override
  Future<String> sendTransferReference(
    String transferId,
    String amount,
    String? note,
  ) async =>
      await room.sendEvent({
        'msgtype': changliaoTransferMessageType,
        'body': '[畅聊点钻转账]',
        'transfer_id': transferId,
        'transfer_amount': amount,
        if (note != null && note.isNotEmpty) 'transfer_note': note,
      }) ??
      (throw StateError('转账消息发送失败'));

  @override
  Future<Uint8List> loadAttachment(String eventId) async {
    final event = timeline.events.firstWhere(
      (candidate) => candidate.eventId == eventId,
    );
    return (await event.downloadAndDecryptAttachment()).bytes;
  }

  @override
  Future<Uint8List?> loadThumbnail(String eventId) async {
    final event = timeline.events.firstWhere(
      (candidate) => candidate.eventId == eventId,
    );
    // 旧消息/未附带缩略图：SDK 的 getThumbnail 会回退为下载完整附件，
    // 这里显式判空返回 null，让调用方走全量路径，避免重复下载。
    if (!event.hasThumbnail) return null;
    final file = await event.downloadAndDecryptAttachment(getThumbnail: true);
    return file.bytes;
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
