import 'dart:typed_data';

import 'room_timeline_controller.dart';
import 'room_timeline_viewport.dart';

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
/// 居中灰字系统消息，双方看到语义一致的好友关系和申请说明，
/// 不得伪装成对方名义的普通气泡消息。
const changliaoFriendAcceptedEventType = 'com.changliao.friend_accepted';

/// 组装好友接受系统消息正文（双端语义一致：互为好友）。
String friendAcceptedSystemMessage(String friendDisplayName) =>
    '你们已成为好友，现在可以开始聊天了。';

Map<String, dynamic> friendAcceptedEventContent({
  required String requesterMatrixUserId,
  required String requesterDisplayName,
  String? requestId,
  String? requestMessage,
}) {
  final message = requestMessage?.trim() ?? '';
  final name = requesterDisplayName.trim().isEmpty
      ? requesterMatrixUserId
      : requesterDisplayName;
  return {
    'body': '${friendAcceptedSystemMessage(name)}'
        '${message.isEmpty ? '' : '\n好友申请说明（申请人：$name）：$message'}',
    'friend_user_id': requesterMatrixUserId,
    'friend_display_name': requesterDisplayName,
    if (requestId != null && requestId.isNotEmpty) 'request_id': requestId,
    'requester_matrix_user_id': requesterMatrixUserId,
    if (message.isNotEmpty) 'request_message': message,
  };
}

String friendAcceptedTransactionId({
  required String roomId,
  required String acceptingUserId,
  String? requestId,
}) =>
    requestId != null && requestId.isNotEmpty
        ? 'friend-accepted-request-$requestId'
        : 'friend-accepted-$roomId-$acceptingUserId';

final class MatrixRoomTimelineAdapter
    implements
        RoomTimelineAdapter,
        RoomOptimisticTextAdapter,
        RoomHistoryStatus,
        RoomWindowedTimelineSource {
  MatrixRoomTimelineAdapter(this._capability);

  final RoomTimelineCapability _capability;

  @override
  List<RoomMessageViewModel> snapshot() {
    final fallback = _fallbackWindow;
    if (fallback != null) {
      final all = _capability.snapshot();
      fallback.update(_hiddenFilter == null
          ? all
          : all.where((m) => !_hiddenFilter!(m.id, m.timestamp)).toList());
      return fallback.snapshot();
    }
    return _capability.snapshot();
  }

  bool Function(String, DateTime?)? _hiddenFilter;
  @override
  void setHiddenFilter(bool Function(String, DateTime?)? hidden) {
    _hiddenFilter = hidden;
    _window?.setHiddenFilter(hidden);
  }

  RoomTimelineViewport<RoomMessageViewModel>? _fallbackWindow;
  RoomWindowedTimelineSource? get _window =>
      _capability is RoomWindowedTimelineSource
          ? _capability as RoomWindowedTimelineSource
          : null;
  @override
  void enableWindow() {
    if (_window != null) {
      _window!.enableWindow();
    } else {
      _fallbackWindow =
          RoomTimelineViewport(idOf: (m) => m.id, project: (m) => m);
      _fallbackWindow!.update(_capability.snapshot());
    }
  }

  @override
  bool get hasEarlierWindow =>
      _window?.hasEarlierWindow ?? _fallbackWindow?.hasEarlier ?? false;
  @override
  bool get hasLaterWindow =>
      _window?.hasLaterWindow ?? _fallbackWindow?.hasLater ?? false;
  @override
  int get totalMessages =>
      _window?.totalMessages ??
      _fallbackWindow?.total ??
      _capability.snapshot().length;
  @override
  Iterable<RoomMessageViewModel> get allMessages =>
      _window?.allMessages ?? _fallbackWindow?.all ?? _capability.snapshot();
  @override
  RoomMessageViewModel? findMessage(String id) =>
      _window?.findMessage(id) ?? _fallbackWindow?.find(id);
  @override
  RoomMessageViewModel? get newestMessage =>
      _window?.newestMessage ?? _fallbackWindow?.newest;
  @override
  DateTime? previousTimestamp(String id) =>
      _window?.previousTimestamp(id) ?? _fallbackWindow?.previousTimestamp(id);
  @override
  bool selectAnchor(String id) =>
      _window?.selectAnchor(id) ?? _fallbackWindow?.anchor(id) ?? false;
  @override
  void selectEarlier() {
    if (_window != null) {
      _window!.selectEarlier();
    } else {
      _fallbackWindow?.earlier();
    }
  }

  @override
  void selectLater() {
    if (_window != null) {
      _window!.selectLater();
    } else {
      _fallbackWindow?.later();
    }
  }

  @override
  void selectLatest() {
    if (_window != null) {
      _window!.selectLatest();
    } else {
      _fallbackWindow?.latest();
    }
  }

  @override
  void pinWindow() {
    if (_window != null) {
      _window!.pinWindow();
    } else {
      _fallbackWindow?.pin();
    }
  }

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
  bool get canLoadHistory => _capability is RoomHistoryStatus
      ? (_capability as RoomHistoryStatus).canLoadHistory
      : true;

  @override
  Future<void> markRead() => _capability.markRead();

  @override
  void dispose() => _capability.dispose();
}
