import 'dart:typed_data';

import 'package:matrix/matrix.dart';

import 'room_timeline_controller.dart';
import 'nudge_service.dart';
import 'group_join_notices.dart';

const changliaoRedPacketMessageType = 'com.changliao.red_packet';

/// 通话结束摘要消息：由呼叫方在通话结束时发送，双端会话各显示一条
/// “通话时长/已取消”行。
const changliaoCallMessageType = 'com.changliao.call';
const changliaoTransferMessageType = 'com.changliao.transfer';

/// BUG 3 好友接受系统消息：accept 方在私聊房间发送，双端渲染为
/// 居中灰字系统消息（"你已添加了 XXX，现在可以开始聊天了。"），
/// 不得伪装成对方名义的普通气泡消息。
const changliaoFriendAcceptedEventType = 'com.changliao.friend_accepted';

/// 组装好友接受系统消息正文（双端语义一致：互为好友）。
String friendAcceptedSystemMessage(String friendDisplayName) =>
    '你已添加了 $friendDisplayName，现在可以开始聊天了。';

final class MatrixRoomTimelineAdapter implements RoomTimelineAdapter {
  MatrixRoomTimelineAdapter(this.room, this.timeline);

  final Room room;
  final Timeline timeline;

  @override
  List<RoomMessageViewModel> snapshot() {
    final viewModels = timeline.events
        .where(
          (event) =>
              event.type == EventTypes.Message ||
              event.type == changliaoNudgeEventType ||
              event.type == changliaoFriendAcceptedEventType,
        )
        .toList(growable: false)
        .reversed
        .map(_message)
        .toList(growable: false);
    // BUG3：入群系统通知——以真实 Matrix 成员事件为唯一权威，本地推导
    // （invite 配对 join 转变），绝不插入本地临时文本；历史重载一致。
    final notices = deriveGroupJoinNotices(
      [for (final event in timeline.events) projectMemberEvent(event)],
      resolveName: (matrixUserId) =>
          room.unsafeGetUserFromMemoryOrFallback(matrixUserId).calcDisplayname(),
    );
    if (notices.isEmpty) return viewModels;
    return mergeNoticesIntoTimeline(viewModels, notices);
  }

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
    final friendAccepted = event.type == changliaoFriendAcceptedEventType;
    final nudgeInfo = nudge
        ? NudgeInfo(
            senderId: event.content['sender_id']?.toString() ?? event.senderId,
            senderName:
                event.content['sender_display_name']?.toString() ?? '好友',
            targetUserId: event.content['target_user_id']?.toString() ?? '',
            targetName:
                event.content['target_display_name']?.toString() ?? '好友',
            suffix: event.content['suffix']?.toString() ?? '',
          )
        : null;
    return RoomMessageViewModel(
      id: event.eventId,
      senderId: event.senderId,
      text: event.redacted
          ? ''
          : friendAccepted
              ? _friendAcceptedBody(event)
              : (nudge ? '' : event.text),
      isOwn: event.senderId == room.client.userID,
      deliveryState: status,
      timestamp: event.originServerTs.toLocal(),
      kind: (nudge || friendAccepted)
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
              ? int.tryParse(event.content['duration_ms']?.toString() ?? '') ??
                  0
              : 0),
      isRecalled: event.redacted,
      replyToEventId: ((event.content['m.relates_to'] as Map?)?['m.in_reply_to']
              as Map?)?['event_id']
          ?.toString(),
      nudge: nudgeInfo,
    );
  }

  /// 好友接受系统消息正文：事件内 body 优先（发送方已拼好），缺失时
  /// 按事件内好友昵称重组。
  static String _friendAcceptedBody(Event event) {
    final body = event.content['body']?.toString();
    if (body != null && body.isNotEmpty) return body;
    return friendAcceptedSystemMessage(
      event.content['friend_display_name']?.toString() ?? '好友',
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


