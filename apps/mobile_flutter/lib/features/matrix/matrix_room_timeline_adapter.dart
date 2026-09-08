import 'dart:typed_data';

import 'room_timeline_controller.dart';

const changliaoRedPacketMessageType = 'com.changliao.red_packet';

/// Lifecycle-managed room operations required by the timeline. Implementations
/// stay behind the Matrix session boundary; no SDK room/timeline is retained by
/// this adapter or its UI consumers.
abstract interface class RoomTimelineCapability {
  List<RoomMessageViewModel> snapshot();
  Future<String> sendText(String text);
  Future<String> sendTextWithTransaction(String text, String transactionId);
  Future<String> sendTransferReference(
      String transferId, String amount, String? note);
  Future<Uint8List?> loadThumbnail(String eventId);
  Future<String> sendRedPacketReference(String packetId, String greeting);
  Future<Uint8List> loadAttachment(String eventId);
  Future<void> retry(String transactionId);
  Future<void> loadHistory();
  Future<void> markRead();
  void dispose();
}

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

final class MatrixRoomTimelineAdapter
    implements RoomTimelineAdapter, RoomOptimisticTextAdapter {
  MatrixRoomTimelineAdapter(this._capability);

  final RoomTimelineCapability _capability;

  @override
  List<RoomMessageViewModel> snapshot() => _capability.snapshot();

  @override
  Future<String> sendText(String text) async => _capability.sendText(text);

  @override
  Future<String> sendTextWithTransaction(String text, String transactionId) =>
      _capability.sendTextWithTransaction(text, transactionId);

  @override
  Future<String> sendRedPacketReference(
    String packetId,
    String greeting,
  ) async =>
      _capability.sendRedPacketReference(packetId, greeting);

  @override
  Future<String> sendTransferReference(
          String transferId, String amount, String? note) =>
      _capability.sendTransferReference(transferId, amount, note);

  @override
  Future<Uint8List?> loadThumbnail(String eventId) =>
      _capability.loadThumbnail(eventId);

  @override
  Future<Uint8List> loadAttachment(String eventId) async {
    return _capability.loadAttachment(eventId);
  }

  @override
  Future<void> retry(String transactionId) async {
    await _capability.retry(transactionId);
  }

  @override
  Future<void> loadHistory() => _capability.loadHistory();

  @override
  Future<void> markRead() => _capability.markRead();

  @override
  void dispose() => _capability.dispose();
}
