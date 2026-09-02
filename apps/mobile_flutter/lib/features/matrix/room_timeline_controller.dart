import 'package:flutter/foundation.dart';

enum RoomDeliveryState { sent, sending, failed }

enum RoomMessageKind { text, image, video, file, voice, redPacket, transfer, call, system }

/// Structured payload of a 拍一拍 (nudge) event. Rendering decides the exact
/// wording per viewer so remarks stay private to the viewer who set them.
final class NudgeInfo {
  const NudgeInfo({
    required this.senderId,
    required this.senderName,
    required this.targetUserId,
    required this.targetName,
    this.suffix = '',
  });

  final String senderId;
  final String senderName;
  final String targetUserId;
  final String targetName;
  final String suffix;
}

final class RoomMessageViewModel {
  const RoomMessageViewModel({
    required this.id,
    required this.senderId,
    required this.text,
    required this.isOwn,
    required this.deliveryState,
    required this.timestamp,
    this.kind = RoomMessageKind.text,
    this.mimeType,
    this.packetId,
    this.greeting,
    this.transferId,
    this.transferAmount,
    this.transferNote,
    this.voiceDuration = const Duration(seconds: 1),
    this.isRecalled = false,
    this.replyToEventId,
    this.nudge,
    this.callVideo = false,
    this.callConnected = false,
    this.callDuration = Duration.zero,
    this.videoDuration,
    this.attachmentSize,
  });

  final String id;
  final String senderId;
  final String text;
  final bool isOwn;
  final RoomDeliveryState deliveryState;
  final DateTime timestamp;
  final RoomMessageKind kind;
  final String? mimeType;
  final String? packetId;
  final String? greeting;
  final String? transferId;
  final String? transferAmount;
  final String? transferNote;
  final Duration voiceDuration;
  final bool isRecalled;
  final String? replyToEventId;
  final NudgeInfo? nudge;

  /// 通话摘要消息（RoomMessageKind.call）：类型/是否接通/时长。
  final bool callVideo;
  final bool callConnected;
  final Duration callDuration;

  /// 视频消息时长（m.video info.duration 毫秒；未知为 null）。
  final Duration? videoDuration;

  /// 原始附件字节数（m.image/m.video/m.file info.size），用于
  /// 查看器“查看原图 xK/M”的精确提示；未知为 null。
  final int? attachmentSize;

  RoomMessageViewModel copyWith({
    String? id,
    RoomDeliveryState? deliveryState,
    NudgeInfo? nudge,
  }) =>
      RoomMessageViewModel(
        id: id ?? this.id,
        senderId: senderId,
        text: text,
        isOwn: isOwn,
        deliveryState: deliveryState ?? this.deliveryState,
        timestamp: timestamp,
        kind: kind,
        mimeType: mimeType,
        packetId: packetId,
        greeting: greeting,
        transferId: transferId,
        transferAmount: transferAmount,
        transferNote: transferNote,
        voiceDuration: voiceDuration,
        isRecalled: isRecalled,
        replyToEventId: replyToEventId,
        nudge: nudge ?? this.nudge,
        attachmentSize: attachmentSize,
      );
}

bool shouldShowMessageTimeSeparator(
  DateTime? previous,
  DateTime current,
) =>
    previous == null ||
    current.difference(previous).abs() >= const Duration(minutes: 5);

abstract interface class RoomTimelineAdapter {
  List<RoomMessageViewModel> snapshot();
  Future<String> sendText(String text);
  Future<String> sendRedPacketReference(String packetId, String greeting);
  Future<String> sendTransferReference(
      String transferId, String amount, String? note);
  Future<Uint8List> loadAttachment(String eventId);

  /// 加载消息附带的压缩缩略图（发送端生成的 ≤800px/≤100KB 减缩版）。
  /// 旧消息无缩略图时返回 null，调用方回退 [loadAttachment] 全量加载。
  Future<Uint8List?> loadThumbnail(String eventId);
  Future<void> retry(String transactionId);
  Future<void> loadHistory();
  Future<void> markRead();
  void dispose();
}

final class RoomTimelineController extends ChangeNotifier {
  RoomTimelineController(this.adapter) : messages = adapter.snapshot();

  final RoomTimelineAdapter adapter;
  List<RoomMessageViewModel> messages;

  /// 历史消息加载状态（上滑到顶自动加载的 UI 反馈）：
  /// [historyLoading] 为 true 时顶部显示加载图标；
  /// [historyExhausted] 为 true 表示已无更多历史（显示"没有更多了"）。
  bool historyLoading = false;
  bool historyExhausted = false;

  Future<void> refresh() async {
    messages = adapter.snapshot();
    notifyListeners();
  }

  /// 重发失败消息：复用同一事务 ID 重试，不插入消息副本。
  Future<void> retry(String transactionId) async {
    await adapter.retry(transactionId);
    await refresh();
  }

  /// 上滑加载更早的历史消息：进行中/已耗尽时为幂等空操作；
  /// 加载后消息数不增长即判定历史已取尽。
  Future<void> loadHistory() async {
    if (historyLoading || historyExhausted) return;
    historyLoading = true;
    notifyListeners();
    try {
      final before = messages.length;
      await adapter.loadHistory();
      messages = adapter.snapshot();
      if (messages.length <= before) historyExhausted = true;
    } finally {
      historyLoading = false;
      notifyListeners();
    }
  }

  Future<void> markRead() => adapter.markRead();

  Future<Uint8List> loadAttachment(String eventId) =>
      adapter.loadAttachment(eventId);

  Future<Uint8List?> loadThumbnail(String eventId) =>
      adapter.loadThumbnail(eventId);

  Future<String> sendRedPacketReference(
    String packetId,
    String greeting,
  ) =>
      adapter.sendRedPacketReference(packetId, greeting);

  Future<String> sendTransferReference(
    String transferId,
    String amount,
    String? note,
  ) =>
      adapter.sendTransferReference(transferId, amount, note);

  Future<void> sendText(String text) async {
    final transactionId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    messages = [
      ...messages,
      RoomMessageViewModel(
        id: transactionId,
        senderId: '',
        text: text,
        isOwn: true,
        deliveryState: RoomDeliveryState.sending,
        timestamp: DateTime.now(),
      ),
    ];
    notifyListeners();
    try {
      final eventId = await adapter.sendText(text);
      messages = [
        for (final message in messages)
          message.id == transactionId
              ? message.copyWith(
                  id: eventId,
                  deliveryState: RoomDeliveryState.sent,
                )
              : message,
      ];
    } catch (_) {
      messages = [
        for (final message in messages)
          message.id == transactionId
              ? message.copyWith(deliveryState: RoomDeliveryState.failed)
              : message,
      ];
    }
    notifyListeners();
  }

  @override
  void dispose() {
    adapter.dispose();
    super.dispose();
  }
}
