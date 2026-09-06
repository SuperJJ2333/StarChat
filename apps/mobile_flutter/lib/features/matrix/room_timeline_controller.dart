import 'package:flutter/foundation.dart';
import '../../core/notification/notification_feedback.dart';
import '../../core/notification/sound_type.dart';

enum RoomDeliveryState { sent, sending, failed }

enum RoomMessageKind {
  text,
  image,
  video,
  file,
  voice,
  redPacket,
  transfer,
  call,
  system
}

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
    this.transactionId,
    this.imageWidth,
    this.imageHeight,
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
  final String? transactionId;
  final int? imageWidth;
  final int? imageHeight;
  String get stableId => transactionId ?? id;

  RoomMessageViewModel copyWith({
    String? id,
    RoomDeliveryState? deliveryState,
    NudgeInfo? nudge,
    DateTime? timestamp,
    String? transactionId,
  }) =>
      RoomMessageViewModel(
        id: id ?? this.id,
        senderId: senderId,
        text: text,
        isOwn: isOwn,
        deliveryState: deliveryState ?? this.deliveryState,
        timestamp: timestamp ?? this.timestamp,
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
        transactionId: transactionId ?? this.transactionId,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        callVideo: callVideo,
        callConnected: callConnected,
        callDuration: callDuration,
        videoDuration: videoDuration,
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

abstract interface class RoomOptimisticTextAdapter {
  Future<String> sendTextWithTransaction(String text, String transactionId);
}

final class RoomTimelineController extends ChangeNotifier {
  RoomTimelineController(this.adapter, {this.canSendNow})
      : messages = adapter.snapshot();

  final RoomTimelineAdapter adapter;

  /// 规格§二/§三：互动权限门（非好友/拉黑 → 消息进入本地 failed，
  /// 绝不触达发送服务；UI 与服务层同一守卫）。
  final bool Function()? canSendNow;
  List<RoomMessageViewModel> messages;
  final Set<String> _retrying = {};
  final _localEchoes = <String, RoomMessageViewModel>{};
  final _sentAt = <String, DateTime>{};
  final _eventTransactions = <String, String>{};
  final _senders = <String, Future<String> Function()>{};
  int _sequence = 0;
  bool _disposed = false;

  List<RoomMessageViewModel> _snapshot() {
    final snapshot = adapter.snapshot();
    final result = <RoomMessageViewModel>[];
    final seen = <String>{};
    for (var message in snapshot) {
      final alias = _eventTransactions[message.id];
      if (alias != null) message = message.copyWith(transactionId: alias);
      String? localKey;
      for (final entry in _localEchoes.entries) {
        if (entry.key == message.stableId || entry.value.id == message.id) {
          localKey = entry.key;
          break;
        }
      }
      if (localKey != null) {
        final local = _localEchoes[localKey]!;
        _eventTransactions[message.id] = localKey;
        message = message.copyWith(
            transactionId: localKey,
            timestamp: local.timestamp,
            deliveryState: message.deliveryState == RoomDeliveryState.sent
                ? RoomDeliveryState.sent
                : local.deliveryState);
        if (message.deliveryState == RoomDeliveryState.sent) {
          _localEchoes.remove(localKey);
        }
      } else if (_sentAt[message.stableId] case final timestamp?) {
        message = message.copyWith(timestamp: timestamp);
      }
      if (seen.add(message.stableId)) result.add(message);
    }
    for (final local in _localEchoes.values) {
      if (seen.add(local.stableId)) result.add(local);
    }
    result.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return result;
  }

  /// 历史消息加载状态（上滑到顶自动加载的 UI 反馈）：
  /// [historyLoading] 为 true 时顶部显示加载图标；
  /// [historyExhausted] 为 true 表示已无更多历史（显示"没有更多了"）。
  bool historyLoading = false;
  bool historyExhausted = false;

  Future<void> refresh() async {
    if (_disposed) return;
    messages = _snapshot();
    notifyListeners();
  }

  /// 重建失败消息的本地发送条目；传输事务 ID 由适配器保留以防重复投递。
  Future<void> retry(String transactionId) async {
    if (_disposed ||
        !(canSendNow?.call() ?? true) ||
        !_retrying.add(transactionId)) {
      return;
    }
    String? tx;
    for (final entry in _localEchoes.entries) {
      if (entry.key == transactionId || entry.value.id == transactionId) {
        tx = entry.key;
        break;
      }
    }
    try {
      if (tx != null) {
        final fresh = _localEchoes[tx]!.copyWith(
            timestamp: DateTime.now(),
            deliveryState: RoomDeliveryState.sending);
        _localEchoes[tx] = fresh;
        _sentAt[tx] = fresh.timestamp;
        messages = _snapshot();
        notifyListeners();
        final exists = adapter
            .snapshot()
            .any((m) => m.id == transactionId || m.stableId == tx);
        if (!exists && _senders.containsKey(tx)) {
          await _dispatch(tx, fresh);
          return;
        }
      }
      await adapter.retry(transactionId);
    } catch (_) {
      if (tx != null && _localEchoes.containsKey(tx)) {
        _localEchoes[tx] =
            _localEchoes[tx]!.copyWith(deliveryState: RoomDeliveryState.failed);
      }
      rethrow;
    } finally {
      _retrying.remove(transactionId);
      await refresh();
    }
  }

  /// 上滑加载更早的历史消息：进行中/已耗尽时为幂等空操作；
  /// 加载后消息数不增长即判定历史已取尽。
  Future<void> loadHistory() async {
    if (_disposed || historyLoading || historyExhausted) return;
    historyLoading = true;
    notifyListeners();
    try {
      final before = messages.length;
      await adapter.loadHistory();
      if (_disposed) return;
      messages = _snapshot();
      if (messages.length <= before) historyExhausted = true;
    } finally {
      historyLoading = false;
      if (!_disposed) notifyListeners();
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

  Future<void> sendText(
    String text, {
    Future<String> Function(String transactionId)? send,
    String? replyToEventId,
    RoomMessageKind kind = RoomMessageKind.text,
    String? mimeType,
    Duration voiceDuration = const Duration(seconds: 1),
  }) async {
    if (_disposed) return;
    final tx = 'local-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
    final permitted = canSendNow?.call() ?? true;
    final local = RoomMessageViewModel(
        id: tx,
        transactionId: tx,
        senderId: '',
        text: text,
        isOwn: true,
        timestamp: DateTime.now(),
        deliveryState:
            permitted ? RoomDeliveryState.sending : RoomDeliveryState.failed,
        replyToEventId: replyToEventId,
        kind: kind,
        mimeType: mimeType,
        voiceDuration: voiceDuration);
    final transport = adapter;
    _senders[tx] = () => send != null
        ? send(tx)
        : transport is RoomOptimisticTextAdapter
            ? (transport as RoomOptimisticTextAdapter)
                .sendTextWithTransaction(text, tx)
            : adapter.sendText(text);
    _localEchoes[tx] = local;
    _sentAt[tx] = local.timestamp;
    messages = [...messages, local];
    notifyListeners();
    if (permitted) await _dispatch(tx, local);
  }

  Future<void> _dispatch(String tx, RoomMessageViewModel local) async {
    try {
      final eventId = await _senders[tx]!();
      if (_disposed) return;
      _eventTransactions[eventId] = tx;
      if (_localEchoes.containsKey(tx)) {
        _localEchoes[tx] =
            local.copyWith(id: eventId, deliveryState: RoomDeliveryState.sent);
      }
      _senders.remove(tx);
      NotificationFeedback.shared.play(SoundType.messageSent);
    } catch (_) {
      if (_disposed) return;
      _localEchoes[tx] =
          local.copyWith(deliveryState: RoomDeliveryState.failed);
    }
    messages = _snapshot();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    adapter.dispose();
    super.dispose();
  }
}
