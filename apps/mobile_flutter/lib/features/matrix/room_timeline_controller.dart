import 'package:flutter/foundation.dart';
import '../../core/notification/notification_feedback.dart';
import '../../core/notification/sound_type.dart';
import '../../core/performance_metrics.dart';

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
    this.isSdkLocalEcho = false,
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

  /// SDK HTTP acknowledgement still carries the device timestamp until /sync.
  final bool isSdkLocalEcho;
  String get stableId => transactionId ?? id;

  /// Exact presentation equality; includes non-text payload and delivery changes.
  bool samePresentation(RoomMessageViewModel other) =>
      identical(this, other) ||
      (id == other.id &&
          senderId == other.senderId &&
          text == other.text &&
          isOwn == other.isOwn &&
          deliveryState == other.deliveryState &&
          timestamp == other.timestamp &&
          kind == other.kind &&
          mimeType == other.mimeType &&
          packetId == other.packetId &&
          greeting == other.greeting &&
          transferId == other.transferId &&
          transferAmount == other.transferAmount &&
          transferNote == other.transferNote &&
          voiceDuration == other.voiceDuration &&
          isRecalled == other.isRecalled &&
          replyToEventId == other.replyToEventId &&
          callVideo == other.callVideo &&
          callConnected == other.callConnected &&
          callDuration == other.callDuration &&
          videoDuration == other.videoDuration &&
          attachmentSize == other.attachmentSize &&
          transactionId == other.transactionId &&
          imageWidth == other.imageWidth &&
          imageHeight == other.imageHeight &&
          isSdkLocalEcho == other.isSdkLocalEcho &&
          nudge?.senderId == other.nudge?.senderId &&
          nudge?.senderName == other.nudge?.senderName &&
          nudge?.targetUserId == other.nudge?.targetUserId &&
          nudge?.targetName == other.nudge?.targetName &&
          nudge?.suffix == other.nudge?.suffix);

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
        isSdkLocalEcho: isSdkLocalEcho,
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

abstract interface class RoomHistoryStatus {
  bool get canLoadHistory;
}

final class RoomTimelineController extends ChangeNotifier {
  RoomTimelineController(this.adapter, {this.canSendNow})
      : messages = List.unmodifiable(adapter.snapshot()) {
    _sourceSnapshot = messages;
    _reindex();
  }

  final RoomTimelineAdapter adapter;

  /// 规格§二/§三：互动权限门（非好友/拉黑 → 消息进入本地 failed，
  /// 绝不触达发送服务；UI 与服务层同一守卫）。
  final bool Function()? canSendNow;
  List<RoomMessageViewModel> messages;
  final _indexById = <String, int>{};

  /// Both server IDs and transaction aliases resolve to the same row in O(1).
  int? indexOf(String id) => _indexById[id];

  void _reindex() {
    _indexById.clear();
    for (var i = 0; i < messages.length; i++) {
      _indexById[messages[i].id] = i;
      _indexById[messages[i].stableId] = i;
    }
  }

  void _publish() {
    _reindex();
    PerformanceMetrics.instance
        .increment(PerformanceCounter.timelineNotification);
    notifyListeners();
  }

  final Set<String> _retrying = {};
  late List<RoomMessageViewModel> _sourceSnapshot;
  int _echoRevision = 0;
  int _projectedEchoRevision = 0;
  final _localEchoes = <String, RoomMessageViewModel>{};
  final _eventTransactions = <String, String>{};
  final _senders = <String, Future<String> Function()>{};
  int _sequence = 0;
  bool _disposed = false;

  List<RoomMessageViewModel> _snapshot() {
    final snapshot = adapter.snapshot();
    // Legacy adapters may return fresh models/lists. Compare before allocating
    // merge structures, including when pending sends have not changed.
    var sameSource = snapshot.length == _sourceSnapshot.length;
    if (sameSource) {
      for (var i = 0; i < snapshot.length; i++) {
        if (!_sourceSnapshot[i].samePresentation(snapshot[i])) {
          sameSource = false;
          break;
        }
      }
    }
    if (sameSource && _echoRevision == _projectedEchoRevision) return messages;
    if (!sameSource) _sourceSnapshot = List.unmodifiable(snapshot);
    _projectedEchoRevision = _echoRevision;
    final result = <RoomMessageViewModel>[];
    final seen = <String>{};
    final pending = <RoomMessageViewModel>[];
    void add(RoomMessageViewModel message) {
      if (!seen.add(message.stableId)) return;
      final previousIndex = _indexById[message.stableId];
      final previous = previousIndex == null ? null : messages[previousIndex];
      result.add(previous != null && previous.samePresentation(message)
          ? previous
          : message);
    }

    for (var message in snapshot) {
      final alias = _eventTransactions[message.id];
      if (alias != null && alias != message.transactionId) {
        message = message.copyWith(transactionId: alias);
      }
      final localKey =
          _localEchoes.containsKey(message.stableId) ? message.stableId : alias;
      final local = _localEchoes[localKey];
      if (local != null) {
        final confirmed = message.deliveryState == RoomDeliveryState.sent &&
            !message.isSdkLocalEcho;
        _eventTransactions[message.id] = localKey!;
        message = message.copyWith(
            transactionId: localKey,
            timestamp: confirmed ? message.timestamp : local.timestamp,
            deliveryState:
                confirmed ? RoomDeliveryState.sent : local.deliveryState);
        if (confirmed) {
          _localEchoes.remove(localKey);
        } else {
          pending.add(message);
          continue;
        }
      }
      add(message);
    }
    // Authoritative rows keep SDK order, including equal timestamps and gaps.
    // Insert only pending sends by their original device insertion timestamp;
    // later incoming rows must not move a failed send to the end on refresh.
    for (final local in [...pending, ..._localEchoes.values]) {
      if (seen.contains(local.stableId)) continue;
      final index =
          result.indexWhere((m) => m.timestamp.isAfter(local.timestamp));
      add(local);
      if (index >= 0) result.insert(index, result.removeLast());
    }
    if (result.length == messages.length) {
      var same = true;
      for (var i = 0; i < result.length; i++) {
        if (!identical(result[i], messages[i])) {
          same = false;
          break;
        }
      }
      if (same) return messages;
    }
    return List.unmodifiable(result);
  }

  // Pending/failed entries have no server timestamp yet. Anchor the insertion
  // after the visible timeline even when the phone clock lags the server.
  // A confirmed event always keeps its authoritative server timestamp.
  DateTime _nextLocalTimestamp() {
    var next = DateTime.now();
    for (final message in messages) {
      if (!next.isAfter(message.timestamp)) {
        next = message.timestamp.add(const Duration(microseconds: 1));
      }
    }
    return next;
  }

  /// 历史消息加载状态（上滑到顶自动加载的 UI 反馈）：
  /// [historyLoading] 为 true 时顶部显示加载图标；
  /// [historyExhausted] 为 true 表示已无更多历史（显示"没有更多了"）。
  bool historyLoading = false;
  bool historyExhausted = false;

  Future<void> refresh() async {
    if (_disposed) return;
    final watch =
        PerformanceMetrics.instance.enabled ? (Stopwatch()..start()) : null;
    final next = _snapshot();
    if (!identical(next, messages)) {
      messages = next;
      _publish();
    }
    if (watch != null) {
      PerformanceMetrics.instance.record(
          PerformanceOperation.timelineRefresh, watch.elapsedMicroseconds);
    }
  }

  /// 重建失败消息的本地发送条目；传输事务 ID 由适配器保留以防重复投递。
  Future<void> retry(String transactionId) async {
    if (_disposed ||
        !(canSendNow?.call() ?? true) ||
        !_retrying.add(transactionId)) {
      return;
    }
    final alias = _eventTransactions[transactionId];
    final tx = _localEchoes.containsKey(transactionId)
        ? transactionId
        : _localEchoes.containsKey(alias)
            ? alias
            : null;
    try {
      if (tx != null) {
        final fresh = _localEchoes[tx]!.copyWith(
            timestamp: _nextLocalTimestamp(),
            deliveryState: RoomDeliveryState.sending);
        _echoRevision++;
        _localEchoes[tx] = fresh;
        messages = _snapshot();
        _publish();
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
        _echoRevision++;
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
    _publish();
    try {
      final before = messages.length;
      await adapter.loadHistory();
      if (_disposed) return;
      messages = _snapshot();
      historyExhausted = adapter is RoomHistoryStatus
          ? !(adapter as RoomHistoryStatus).canLoadHistory
          : messages.length <= before;
    } finally {
      historyLoading = false;
      if (!_disposed) _publish();
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
        timestamp: _nextLocalTimestamp(),
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
    _echoRevision++;
    _localEchoes[tx] = local;
    messages = [...messages, local];
    _publish();
    if (permitted) await _dispatch(tx, local);
  }

  Future<void> _dispatch(String tx, RoomMessageViewModel local) async {
    try {
      final eventId = await _senders[tx]!();
      if (_disposed) return;
      _echoRevision++;
      _eventTransactions[eventId] = tx;
      if (_localEchoes.containsKey(tx)) {
        _localEchoes[tx] =
            local.copyWith(id: eventId, deliveryState: RoomDeliveryState.sent);
      }
      _senders.remove(tx);
      NotificationFeedback.shared.play(SoundType.messageSent);
    } catch (_) {
      if (_disposed) return;
      _echoRevision++;
      _localEchoes[tx] =
          local.copyWith(deliveryState: RoomDeliveryState.failed);
    }
    messages = _snapshot();
    _publish();
  }

  @override
  void dispose() {
    _disposed = true;
    adapter.dispose();
    super.dispose();
  }
}
