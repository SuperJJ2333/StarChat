import 'dart:async';
import 'room_history_date_capability.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import '../../core/network_state_manager.dart';
import '../../core/notification/notification_feedback.dart';
import '../../core/notification/sound_type.dart';
import '../../core/outbox/outbox_message.dart';
import '../../core/outbox/persistent_outbox_manager.dart';
import '../../core/performance_metrics.dart';

/// 发出消息的本地投递状态机（离线优先）。
///
/// - [local]：乐观行已创建，但派发尚未开始；
/// - [sending]：已交给传输层，等待服务端确认；
/// - [waitingNetwork]：因**网络**原因（[defaultNetworkFailureClassifier]）
///   发送失败，等待网络恢复后自动重发——弱网/无网绝不显示成硬失败；
/// - [failed]：终局失败（服务端拒绝、无权限、互动门禁等），只能手动重试；
/// - [sent]：服务端已确认。
///
/// 与持久化的 [OutboxStatus] 一一对应（`local → queued`、
/// `sending → sending`、`waitingNetwork → waitingNetwork`、
/// `failed → failed`、`sent → sent`）；内存里的乐观行负责"当前这一屏"，
/// outbox 行负责跨进程不丢消息。
enum RoomDeliveryState { local, sending, waitingNetwork, failed, sent }

/// 内存投递状态 → 持久化 outbox 状态（唯一映射点，避免两套词表漂移）。
OutboxStatus outboxStatusOf(RoomDeliveryState state) => switch (state) {
      RoomDeliveryState.local => OutboxStatus.queued,
      RoomDeliveryState.sending => OutboxStatus.sending,
      RoomDeliveryState.waitingNetwork => OutboxStatus.waitingNetwork,
      RoomDeliveryState.failed => OutboxStatus.failed,
      RoomDeliveryState.sent => OutboxStatus.sent,
    };

/// 持久化 outbox 状态 → 内存投递状态（恢复历史行时使用）。
RoomDeliveryState roomDeliveryStateOf(OutboxStatus status) => switch (status) {
      OutboxStatus.queued => RoomDeliveryState.local,
      OutboxStatus.sending => RoomDeliveryState.sending,
      OutboxStatus.waitingNetwork => RoomDeliveryState.waitingNetwork,
      OutboxStatus.failed => RoomDeliveryState.failed,
      OutboxStatus.sent => RoomDeliveryState.sent,
    };

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
    this.transferReceiverId,
    this.transferReceiverMatrixId,
    this.redPacketMode,
    this.redPacketRecipientId,
    this.redPacketRecipientMatrixId,
    this.voiceDuration = const Duration(seconds: 1),
    this.isRecalled = false,
    this.replyToEventId,
    this.replyExcerpt,
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
    this.isFlashPhoto = false,
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

  /// 群聊转账的收款对象（发送时随消息一起写入房间，仅账号标识）。
  /// 业务明细对第三方不可见时，本机用它解析展示名（本机备注 → 昵称）。
  final String? transferReceiverId;
  final String? transferReceiverMatrixId;

  /// 红包类型与专属红包的指定对象（同上，仅用于第三方只读展示）。
  final String? redPacketMode;
  final String? redPacketRecipientId;
  final String? redPacketRecipientMatrixId;
  final Duration voiceDuration;
  final bool isRecalled;
  final String? replyToEventId;
  final String? replyExcerpt;
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

  /// 闪照：m.image 事件附带 flash=1。接收端仅渲染马赛克缩略，
  /// 长按限时查看原图，阅后销毁且禁止转发。
  final bool isFlashPhoto;
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
          transferReceiverId == other.transferReceiverId &&
          transferReceiverMatrixId == other.transferReceiverMatrixId &&
          redPacketMode == other.redPacketMode &&
          redPacketRecipientId == other.redPacketRecipientId &&
          redPacketRecipientMatrixId == other.redPacketRecipientMatrixId &&
          voiceDuration == other.voiceDuration &&
          isRecalled == other.isRecalled &&
          replyToEventId == other.replyToEventId &&
          replyExcerpt == other.replyExcerpt &&
          callVideo == other.callVideo &&
          callConnected == other.callConnected &&
          callDuration == other.callDuration &&
          videoDuration == other.videoDuration &&
          attachmentSize == other.attachmentSize &&
          transactionId == other.transactionId &&
          imageWidth == other.imageWidth &&
          imageHeight == other.imageHeight &&
          isSdkLocalEcho == other.isSdkLocalEcho &&
          isFlashPhoto == other.isFlashPhoto &&
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
    String? replyExcerpt,
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
        transferReceiverId: transferReceiverId,
        transferReceiverMatrixId: transferReceiverMatrixId,
        redPacketMode: redPacketMode,
        redPacketRecipientId: redPacketRecipientId,
        redPacketRecipientMatrixId: redPacketRecipientMatrixId,
        voiceDuration: voiceDuration,
        isRecalled: isRecalled,
        replyToEventId: replyToEventId,
        replyExcerpt: replyExcerpt ?? this.replyExcerpt,
        nudge: nudge ?? this.nudge,
        attachmentSize: attachmentSize,
        transactionId: transactionId ?? this.transactionId,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        isSdkLocalEcho: isSdkLocalEcho,
        isFlashPhoto: isFlashPhoto,
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

  /// 发送红包引用消息。[mode]/[recipientId]/[recipientMatrixId] 描述红包类型
  /// 与专属对象，随消息进入房间（仅为账号标识，供其他成员本机解析展示名）。
  Future<String> sendRedPacketReference(String packetId, String greeting,
      {String? mode, String? recipientId, String? recipientMatrixId});

  /// 发送转账引用消息。[receiverId]/[receiverMatrixId] 为目的收款账号标识。
  Future<String> sendTransferReference(
      String transferId, String amount, String? note,
      {String? receiverId, String? receiverMatrixId});
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

/// A context fragment may have newer remote pages even when its visible
/// viewport is already at the latest loaded row.
abstract interface class RoomFutureHistoryStatus {
  bool get hasFutureHistory;
  Future<void> loadFutureHistory();
}

/// Compatibility name for the single optional date/context capability.
typedef RoomHistoryDateSource = RoomHistoryDateCapability;

/// 引用原消息解析被服务端**权威拒绝**（无权限：`M_FORBIDDEN`/`M_UNAUTHORIZED`）。
///
/// 与网络失败严格区分：无权限是可以直接告诉用户的终局结论，不该被显示成
/// 「加载失败，点击重试」让用户反复徒劳重试。
final class ReplyMessageLookupDenied implements Exception {
  const ReplyMessageLookupDenied([this.detail = '']);

  final String detail;

  @override
  String toString() => 'ReplyMessageLookupDenied($detail)';
}

/// 引用原消息解析暂时不可用（网络中断、超时、服务器 5xx）。
///
/// 语义是「可重试」，与 [ReplyMessageLookupDenied] 互斥。
final class ReplyMessageLookupUnavailable implements Exception {
  const ReplyMessageLookupUnavailable([this.detail = '']);

  final String detail;

  @override
  String toString() => 'ReplyMessageLookupUnavailable($detail)';
}

/// 可选能力：按 `event_id` 直接解析**单条**消息。
///
/// 引用卡片用它恢复距离过远的原消息，避免为了找到一条消息而从窗口顶端
/// 逐页加载上千条历史。实现必须遵守：
/// - 本地加密库优先，未命中才请求服务器（SDK `Room.getEventById` 语义）；
/// - 返回 `null` 表示服务端权威确认不存在；
/// - 无权限抛 [ReplyMessageLookupDenied]，暂时不可用抛
///   [ReplyMessageLookupUnavailable]。
abstract interface class RoomMessageLookupSource {
  /// 是否真的支持单事件解析。转发型适配器在底层能力不支持时必须返回
  /// `false`，让调用方回退到历史分页，而不是把「不支持」误报成「不存在」。
  bool get supportsMessageLookup;

  Future<RoomMessageViewModel?> lookupMessage(String eventId);
}

/// Optional SDK-backed viewport. Full history stays queryable without retaining
/// presentation objects for every event. Legacy adapters remain valid.
abstract interface class RoomWindowedTimelineSource {
  void enableWindow();
  void setHiddenFilter(bool Function(String id, DateTime? timestamp)? hidden);
  bool get hasEarlierWindow;
  bool get hasLaterWindow;
  int get totalMessages;
  Iterable<RoomMessageViewModel> get allMessages;
  RoomMessageViewModel? findMessage(String id);
  RoomMessageViewModel? get newestMessage;
  DateTime? previousTimestamp(String id);
  bool selectAnchor(String id);
  void selectEarlier();
  void selectLater();
  void selectLatest();
  void pinWindow();
}

final class RoomTimelineController extends ChangeNotifier {
  RoomTimelineController(this.adapter,
      {this.canSendNow,
      bool windowed = false,
      NetworkStateManager? networkStateManager,
      OutboxJournal? outboxJournal})
      : _injectedNetworkState = networkStateManager,
        _outboxJournal = outboxJournal {
    if (windowed && adapter is RoomWindowedTimelineSource) {
      _windowSource = adapter as RoomWindowedTimelineSource;
      _windowSource!.enableWindow();
    }
    messages = List.unmodifiable(adapter.snapshot());
    _sourceSnapshot = messages;
    _publishedNewestId = newestMessage?.id;
    _publishedHasLater = hasLaterWindow;
    _publishedViewingHistory = isViewingHistoryContext;
    _updateReplyDependencies(messages);
    _reindex();
  }

  final RoomTimelineAdapter adapter;

  /// 规格§二/§三：互动权限门（非好友/拉黑 → 消息进入本地 failed，
  /// 绝不触达发送服务；UI 与服务层同一守卫）。
  final bool Function()? canSendNow;
  late List<RoomMessageViewModel> messages;
  RoomWindowedTimelineSource? _windowSource;
  bool get hasEarlierWindow => _windowSource?.hasEarlierWindow ?? false;
  bool get hasLaterWindow => _windowSource?.hasLaterWindow ?? false;
  bool get hasFutureHistory =>
      adapter is RoomFutureHistoryStatus &&
      (adapter as RoomFutureHistoryStatus).hasFutureHistory;
  int get totalMessages => _windowSource?.totalMessages ?? messages.length;
  Iterable<RoomMessageViewModel> get allMessages sync* {
    final seen = <String>{};
    for (var message in _windowSource?.allMessages ?? messages) {
      final tx = _eventTransactions[message.id];
      if (tx != null) message = message.copyWith(transactionId: tx);
      if (seen.add(message.stableId)) yield message;
    }
    for (final message in _localEchoes.values) {
      if (seen.add(message.stableId)) yield message;
    }
  }

  /// 引用目标解析成功后保留的投影，供 [findMessage] 命中（窗口外的消息
  /// 不在 `messages` 投影里）。容量有界，仅保存引用卡片需要展示的字段。
  final _resolvedReplyTargets = <String, RoomMessageViewModel>{};
  static const int _maxResolvedReplyTargets = 128;

  RoomMessageViewModel? findMessage(String id) {
    final index = indexOf(id);
    if (index != null) return messages[index];
    return _windowSource?.findMessage(id) ?? _resolvedReplyTargets[id];
  }

  /// 单条消息的按需解析（引用原消息恢复）。
  ///
  /// 适配器实现 [RoomMessageLookupSource] 时走**单事件查询**：本地加密库
  /// 优先，未命中才请求服务器——远距离原消息一次往返即可恢复，而不是从
  /// 窗口顶端逐页翻上千条。旧适配器回退到**有界**历史分页
  /// （[replyHistoryPageBudget] 页），绝不无限拉取历史。
  Future<RoomMessageViewModel?> lookupReplyMessage(String eventId) async {
    if (_disposed || eventId.isEmpty) return null;
    final existing = findMessage(eventId);
    if (existing != null) return existing;
    final source = adapter;
    if (source is RoomMessageLookupSource &&
        (source as RoomMessageLookupSource).supportsMessageLookup) {
      final found =
          await (source as RoomMessageLookupSource).lookupMessage(eventId);
      if (_disposed) return found;
      if (found != null) _rememberResolvedReplyTarget(found);
      await refresh();
      return found;
    }
    return _lookupReplyByHistoryPaging(eventId);
  }

  /// 旧适配器的兼容回退：分页补齐有界页数，加载过的页仍写入 SDK 本地库。
  static const int replyHistoryPageBudget = 2;

  Future<RoomMessageViewModel?> _lookupReplyByHistoryPaging(
      String eventId) async {
    for (var page = 0; page < replyHistoryPageBudget; page++) {
      if (_disposed || historyExhausted) return null;
      final before = messages.length;
      await loadHistory();
      if (_disposed) return null;
      final found = findMessage(eventId);
      if (found != null) return found;
      // 本页没有新增（历史取尽或请求被取消）→ 不再空转。
      if (messages.length <= before) return null;
    }
    return null;
  }

  void _rememberResolvedReplyTarget(RoomMessageViewModel message) {
    _resolvedReplyTargets.remove(message.id);
    _resolvedReplyTargets[message.id] = message;
    while (_resolvedReplyTargets.length > _maxResolvedReplyTargets) {
      _resolvedReplyTargets.remove(_resolvedReplyTargets.keys.first);
    }
  }

  /// 消息撤回/删除或本地历史清空后丢弃对应投影，避免引用卡片展示
  /// 已经不可见的内容。
  void forgetResolvedReplyTarget(String eventId) =>
      _resolvedReplyTargets.remove(eventId);

  void clearResolvedReplyTargets() => _resolvedReplyTargets.clear();

  RoomMessageViewModel? get newestMessage => _windowSource != null
      ? _windowSource!.newestMessage
      : messages.lastOrNull;
  DateTime? previousTimestamp(String id) =>
      _windowSource?.previousTimestamp(id);
  void pinWindow() => _windowSource?.pinWindow();
  void setHiddenFilter(bool Function(String id, DateTime? timestamp)? hidden) =>
      _windowSource?.setHiddenFilter(hidden);
  Future<bool> openAnchor(String id) async {
    final found = _windowSource?.selectAnchor(id) ?? indexOf(id) != null;
    if (found) {
      _echoRevision++;
      await refresh();
    }
    return found;
  }

  Future<void> showLatest() async {
    _restoreLatest();
    await refresh();
  }

  void _restoreLatest() {
    _timelineOperationGeneration++;
    _activeHistoryRequest = null;
    _historyLoadingOwner = null;
    historyExhausted = false;
    if (adapter is RoomHistoryDateCapability) {
      (adapter as RoomHistoryDateCapability).selectLatest();
    } else {
      _windowSource?.selectLatest();
    }
    _echoRevision++;
  }

  Future<void> showEarlierWindow() async {
    _windowSource?.selectEarlier();
    _echoRevision++;
    await refresh();
  }

  Future<void> showLaterWindow() async {
    _windowSource?.selectLater();
    _echoRevision++;
    await refresh();
  }

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
  bool _publishedViewingHistory = false;
  final _localEchoes = <String, RoomMessageViewModel>{};
  final _eventTransactions = <String, String>{};
  final _senders = <String, Future<String> Function()>{};
  int _sequence = 0;
  bool _disposed = false;

  /// 出站消息持久化日志（`PersistentOutboxManager.journalFor(...)`）。
  ///
  /// null = 不落盘（纯逻辑测试、或没有可用持久层），此时行为与旧实现完全
  /// 一致：乐观行 + 内存重发。非 null 时**先落盘再派发**，且重试/重启
  /// 一律复用同一 txid。
  final OutboxJournal? _outboxJournal;

  /// 同一 txid 在途去重：恢复流程与用户点击可能同时命中同一行。
  final _inFlightTxids = <String>{};

  /// 最近一次 outbox 持久化错误（诊断；不阻断发送）。
  Object? outboxError;

  /// 组合根/测试注入的网络状态源。为 null 时回退到进程级
  /// [NetworkStateManager.shared]（纯逻辑测试或组合根尚未接线时为 null）。
  final NetworkStateManager? _injectedNetworkState;

  /// 已挂载恢复监听的网络状态源（[dispose] 时解绑）。
  NetworkStateManager? _recoveryManager;
  bool _recoveryAttached = false;

  /// 因**网络**原因发送失败、等待网络恢复后自动重发的行（txid）。
  /// 只保存本地乐观行，重发复用同一 txid 与捕获的发送回调。
  final _waitingNetworkIds = <String>{};
  bool _drainingWaitingNetwork = false;

  NetworkStateManager? get _networkState =>
      _injectedNetworkState ?? NetworkStateManager.shared;

  bool get _networkIsUsable {
    final state = _networkState?.current;
    return state == NetworkState.online || state == NetworkState.recovering;
  }

  /// 网络失败判定（SocketException / TimeoutException / HttpException /
  /// ClientException / 5xx）。非网络错误一律不许降级成「等待发送」。
  bool _isNetworkFailure(Object error) =>
      defaultNetworkFailureClassifier(error);

  /// 挂载一次网络恢复监听：状态进入 online/recovering 时重发所有
  /// `waitingNetwork` 行。只挂一次、不创建任何定时器、[dispose] 时解绑。
  void _attachNetworkRecoveryWatch() {
    if (_disposed || _recoveryAttached) return;
    final manager = _networkState;
    if (manager == null) return;
    _recoveryAttached = true;
    _recoveryManager = manager;
    manager.state.addListener(_handleNetworkStateChanged);
    // 行进入等待时管理器可能已经认为网络可用（例如失败由别的层上报）。
    // `whenOnline()` 在此情况下立即完成且不排定时器，因此直接排水一次。
    if (_networkIsUsable) unawaited(_drainWaitingNetwork());
  }

  void _handleNetworkStateChanged() {
    if (_disposed || !_networkIsUsable) return;
    unawaited(_drainWaitingNetwork());
  }

  /// 自动重发所有等待网络的消息。
  ///
  /// 幂等：并发排水、重复的恢复通知、手动重试在途都不会二次派发同一行；
  /// 每次派发都复用**同一个** txid（`_senders` 仅在成功后才移除）。
  Future<void> _drainWaitingNetwork() async {
    if (_disposed ||
        _drainingWaitingNetwork ||
        _waitingNetworkIds.isEmpty ||
        !(canSendNow?.call() ?? true)) {
      return;
    }
    _drainingWaitingNetwork = true;
    try {
      for (final tx in List<String>.of(_waitingNetworkIds)) {
        if (_disposed) return;
        // 重发途中再次掉线：余下的行继续等待，不做无谓的失败派发。
        if (!_networkIsUsable) break;
        if (!_waitingNetworkIds.contains(tx)) continue;
        // 已经不在本地乐观行里的 txid（例如已被撤回/清空）不再重发。
        if (!_localEchoes.containsKey(tx)) {
          _waitingNetworkIds.remove(tx);
          continue;
        }
        await _retry(tx, rethrowErrors: false);
      }
    } finally {
      _drainingWaitingNetwork = false;
    }
  }

  /// 记录一次派发失败并返回该行应处的状态。
  ///
  /// 网络失败 → [RoomDeliveryState.waitingNetwork]（并上报给网络状态机，
  /// 便于恢复时自动重发）；服务端拒绝/权限/互动门禁等非网络失败 →
  /// 终局 [RoomDeliveryState.failed]。
  RoomDeliveryState _noteFailure(String tx, Object error) {
    if (_isNetworkFailure(error)) {
      _networkState?.reportFailure(error);
      _waitingNetworkIds.add(tx);
      _attachNetworkRecoveryWatch();
      return RoomDeliveryState.waitingNetwork;
    }
    _waitingNetworkIds.remove(tx);
    return RoomDeliveryState.failed;
  }

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
    for (final local in [
      ...pending,
      if (!hasLaterWindow) ..._localEchoes.values
    ]) {
      if (seen.contains(local.stableId)) continue;
      final index =
          result.indexWhere((m) => m.timestamp.isAfter(local.timestamp));
      add(local);
      if (index >= 0) result.insert(index, result.removeLast());
    }
    if (_windowSource != null && result.length > 200) {
      result.removeRange(0, result.length - 200);
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
    final newest = newestMessage;
    for (final message in [
      if (newest != null) newest,
      ..._localEchoes.values
    ]) {
      if (!next.isAfter(message.timestamp)) {
        next = message.timestamp.add(const Duration(microseconds: 1));
      }
    }
    return next;
  }

  /// 历史消息加载状态（上滑到顶自动加载的 UI 反馈）：
  /// [historyLoading] 为 true 时顶部显示加载图标；
  /// [historyExhausted] 为 true 表示已无更多历史（显示"没有更多了"）。
  Object? _activeHistoryRequest;
  Object? _historyLoadingOwner;
  bool get historyLoading => _historyLoadingOwner != null;
  bool historyExhausted = false;
  int _timelineOperationGeneration = 0;

  int? _refreshFrame;
  Timer? _refreshDeadline;
  String? _publishedNewestId;
  bool _publishedHasLater = false;

  /// SDK bursts share one scheduled frame. Background/no-frame delivery still
  /// publishes within 50 ms. Explicit local operations call refresh directly.
  void scheduleRefresh() {
    if (_disposed || _refreshFrame != null) return;
    void flush() {
      final frame = _refreshFrame;
      _refreshFrame = null;
      if (frame != null) {
        SchedulerBinding.instance.cancelFrameCallbackWithId(frame);
      }
      _refreshDeadline?.cancel();
      _refreshDeadline = null;
      if (!_disposed) unawaited(refresh());
    }

    _refreshFrame =
        SchedulerBinding.instance.scheduleFrameCallback((_) => flush());
    _refreshDeadline = Timer(const Duration(milliseconds: 50), flush);
  }

  final _replyDependencies = <String, RoomMessageViewModel?>{};
  bool _updateReplyDependencies(List<RoomMessageViewModel> active) {
    if (_windowSource == null) return false;
    final ids = {
      for (final m in active)
        if (m.replyToEventId != null) m.replyToEventId!
    };
    var changed = false;
    _replyDependencies.removeWhere((id, _) => !ids.contains(id));
    for (final id in ids) {
      final next = _windowSource!.findMessage(id);
      final before = _replyDependencies[id];
      if (before == null
          ? next != null
          : next == null || !before.samePresentation(next)) {
        changed = true;
      }
      _replyDependencies[id] = next;
    }
    return changed;
  }

  Future<void> refresh() async {
    if (_disposed) return;
    final watch =
        PerformanceMetrics.instance.enabled ? (Stopwatch()..start()) : null;
    final next = _snapshot();
    final newestId = newestMessage?.id;
    final viewingHistory = isViewingHistoryContext;
    final repliesChanged = _updateReplyDependencies(next);
    if (repliesChanged ||
        !identical(next, messages) ||
        newestId != _publishedNewestId ||
        hasLaterWindow != _publishedHasLater ||
        viewingHistory != _publishedViewingHistory) {
      messages = next;
      _publishedNewestId = newestId;
      _publishedHasLater = hasLaterWindow;
      _publishedViewingHistory = viewingHistory;
      _publish();
    }
    if (watch != null) {
      PerformanceMetrics.instance.record(
          PerformanceOperation.timelineRefresh, watch.elapsedMicroseconds);
    }
  }

  /// 重建失败消息的本地发送条目；传输事务 ID 由适配器保留以防重复投递。
  ///
  /// 手动重试：把 `failed` / `waitingNetwork` 行翻回 [RoomDeliveryState.sending]
  /// 并复用捕获的发送回调与同一 txid。
  Future<void> retry(String transactionId) =>
      _retry(transactionId, rethrowErrors: true);

  Future<void> _retry(String transactionId,
      {required bool rethrowErrors}) async {
    if (_disposed || !(canSendNow?.call() ?? true)) return;
    if (!_retrying.add(transactionId)) return;
    final alias = _eventTransactions[transactionId];
    final tx = _localEchoes.containsKey(transactionId)
        ? transactionId
        : _localEchoes.containsKey(alias)
            ? alias
            : null;
    if (tx != null) _waitingNetworkIds.remove(tx);
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
      // 适配器重试成功（SDK 已确认）：outbox 行同样落定，避免重启后再发一次。
      if (tx != null && _localEchoes.containsKey(tx)) {
        await _persistOutboxOutcome(
            tx, _localEchoes[tx]!, RoomDeliveryState.sent,
            error: null);
      }
    } catch (error) {
      if (tx != null && _localEchoes.containsKey(tx)) {
        _echoRevision++;
        final state = _noteFailure(tx, error);
        _localEchoes[tx] = _localEchoes[tx]!.copyWith(deliveryState: state);
        // 手动重试同样要把结果写回 outbox，否则重启后状态会漂移。
        await _persistOutboxOutcome(tx, _localEchoes[tx]!, state,
            error: error);
      }
      if (rethrowErrors) rethrow;
    } finally {
      _retrying.remove(transactionId);
      await refresh();
    }
  }

  /// 上滑加载更早的历史消息：进行中/已耗尽时为幂等空操作；
  /// 加载后消息数不增长即判定历史已取尽。
  Future<void> loadHistory() async {
    if (_disposed || _activeHistoryRequest != null || historyExhausted) return;
    final generation = _timelineOperationGeneration;
    final owner = Object();
    _activeHistoryRequest = owner;
    _historyLoadingOwner = owner;
    _publish();
    try {
      final before = messages.length;
      await adapter.loadHistory();
      if (_disposed ||
          !identical(_activeHistoryRequest, owner) ||
          generation != _timelineOperationGeneration) {
        return;
      }
      messages = _snapshot();
      historyExhausted = adapter is RoomHistoryStatus
          ? !(adapter as RoomHistoryStatus).canLoadHistory
          : messages.length <= before;
    } finally {
      if (identical(_activeHistoryRequest, owner)) {
        _activeHistoryRequest = null;
        if (identical(_historyLoadingOwner, owner)) {
          _historyLoadingOwner = null;
        }
        if (!_disposed) _publish();
      }
    }
  }

  /// Loads newer remote pages for an anchored context. This is deliberately
  /// distinct from [showLaterWindow], which only shifts already loaded rows.
  Future<void> loadFutureHistory() async {
    if (_disposed || adapter is! RoomFutureHistoryStatus) return;
    final source = adapter as RoomFutureHistoryStatus;
    if (_activeHistoryRequest != null || !source.hasFutureHistory) return;
    final generation = _timelineOperationGeneration;
    final owner = Object();
    _activeHistoryRequest = owner;
    try {
      await source.loadFutureHistory();
      if (_disposed ||
          !identical(_activeHistoryRequest, owner) ||
          generation != _timelineOperationGeneration) {
        return;
      }
      historyExhausted = false;
      await refresh();
    } finally {
      if (identical(_activeHistoryRequest, owner)) {
        _activeHistoryRequest = null;
      }
    }
  }

  Future<void> markRead() => adapter.markRead();

  Iterable<RoomHistoryDayMetadata> get loadedDayMetadata =>
      adapter is RoomHistoryDateCapability
          ? (adapter as RoomHistoryDateCapability).loadedDayMetadata
          : const [];

  bool get isViewingHistoryContext =>
      adapter is RoomHistoryDateCapability &&
      (adapter as RoomHistoryDateCapability).isViewingHistoryContext;

  Future<RoomHistoryDayLocation?> locateDay(DateTime localDay) async {
    if (_disposed || adapter is! RoomHistoryDateCapability) return null;
    final generation = ++_timelineOperationGeneration;
    final wasLoading = historyLoading;
    _activeHistoryRequest = null;
    _historyLoadingOwner = null;
    if (wasLoading) _publish();
    final location =
        await (adapter as RoomHistoryDateCapability).locateDay(localDay);
    if (_disposed ||
        generation != _timelineOperationGeneration ||
        location == null) {
      return null;
    }
    historyExhausted = false;
    await refresh();
    return location;
  }

  /// 日期索引中已知的最早月份（可为 null = 未知，**不得**回退成 1970）。
  CalendarMonth? get earliestMonth => adapter is RoomHistoryDateCapability
      ? (adapter as RoomHistoryDateCapability).earliestMonth
      : null;

  /// 月级 metadata 查询（只读日期状态；不加载正文/媒体）。
  ///
  /// 本地索引优先，覆盖不足时有界探测；过期结果由 capability 的 generation
  /// guard 丢弃，调用方还需用自己的 generation 再次校验。
  Future<RoomHistoryMonthDays> loadMonthDays(CalendarMonth month) {
    if (_disposed || adapter is! RoomHistoryDateCapability) {
      return Future.value(RoomHistoryMonthDays(month: month));
    }
    return (adapter as RoomHistoryDateCapability).loadMonthDays(month);
  }

  void cancelMonthLookup() {
    if (_disposed) return;
    if (adapter is RoomHistoryDateCapability) {
      (adapter as RoomHistoryDateCapability).cancelMonthLookup();
    }
  }

  /// 该日已知 anchor（月 metadata 已给出时跳过重复 timestamp_to_event）。
  String? anchorForDay(DateTime localDay) => adapter is RoomHistoryDateCapability
      ? (adapter as RoomHistoryDateCapability).anchorForDay(localDay)
      : null;

  void cancelPendingDateLookup() {
    if (_disposed) return;
    _timelineOperationGeneration++;
    final wasLoading = historyLoading;
    _activeHistoryRequest = null;
    _historyLoadingOwner = null;
    if (adapter is RoomHistoryDateCapability) {
      (adapter as RoomHistoryDateCapability).cancelPendingDateLookup();
    }
    if (wasLoading) _publish();
  }

  Future<void> selectLatest() => showLatest();

  Future<Uint8List> loadAttachment(String eventId) =>
      adapter.loadAttachment(eventId);

  Future<Uint8List?> loadThumbnail(String eventId) =>
      adapter.loadThumbnail(eventId);

  Future<String> sendRedPacketReference(
    String packetId,
    String greeting, {
    String? mode,
    String? recipientId,
    String? recipientMatrixId,
  }) =>
      adapter.sendRedPacketReference(packetId, greeting,
          mode: mode, recipientId: recipientId,
          recipientMatrixId: recipientMatrixId);

  Future<String> sendTransferReference(
    String transferId,
    String amount,
    String? note, {
    String? receiverId,
    String? receiverMatrixId,
  }) =>
      adapter.sendTransferReference(transferId, amount, note,
          receiverId: receiverId, receiverMatrixId: receiverMatrixId);

  /// 发送一条文本消息（用户点击发送 / 恢复流程 / 初始 outbox 共用本路径）。
  ///
  /// 顺序**绝不**颠倒：创建乐观行 → **先持久化 outbox 行** → 交给传输层 →
  /// 按结果更新状态。因此进程在任意时刻死掉，消息都还在本地 outbox 里。
  ///
  /// [outboxRow] 由恢复流程传入：复用该行**原有的 txid**（幂等）与状态；
  /// 为空时按当前时间生成新 txid（只在"新建一条消息"时发生一次）。
  ///
  /// 返回服务端 event id（未派发/失败时为 null）。性能契约不变：一条本地
  /// 消息只产生一次可见发布。
  Future<String?> sendText(
    String text, {
    Future<String> Function(String transactionId)? send,
    String? replyToEventId,
    String? replyExcerpt,
    RoomMessageKind kind = RoomMessageKind.text,
    String? mimeType,
    Duration voiceDuration = const Duration(seconds: 1),
    bool isFlashPhoto = false,
    OutboxMessage? outboxRow,
  }) async {
    if (_disposed) return null;
    _restoreLatest();
    messages = _snapshot();
    _reindex();
    final tx = outboxRow?.txid ??
        'local-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
    // 同一 txid 只允许一次在途派发：恢复流程与用户点击可能同时命中同一行。
    if (_inFlightTxids.contains(tx)) return null;
    final permitted = canSendNow?.call() ?? true;
    final local = RoomMessageViewModel(
        id: tx,
        transactionId: tx,
        senderId: '',
        text: text,
        isOwn: true,
        timestamp: outboxRow == null
            ? _nextLocalTimestamp()
            : _localTimestampFor(outboxRow.createdAt),
        deliveryState:
            permitted ? RoomDeliveryState.local : RoomDeliveryState.failed,
        replyToEventId: replyToEventId,
        replyExcerpt: replyExcerpt,
        kind: kind,
        mimeType: mimeType,
        voiceDuration: voiceDuration,
        isFlashPhoto: isFlashPhoto);
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
    if (_windowSource != null && messages.length > 200) {
      messages = List.unmodifiable(messages.skip(messages.length - 200));
    }
    _publish();
    if (!permitted) {
      await _persistOutboxOutcome(tx, local, RoomDeliveryState.failed,
          error: null, outboxRow: outboxRow);
      return null;
    }
    return _dispatch(tx, local, outboxRow: outboxRow);
  }

  /// 恢复一条持久化的 outbox 行到时间线，但**不派发**（例如服务端已明确
  /// 拒绝过的 `failed` 行，或还没轮到派发的行）。用户点击重试仍走既有
  /// [retry] 路径，复用同一 txid。
  void restoreOutboxMessage(OutboxMessage row) {
    if (_disposed || row.content.trim().isEmpty) return;
    final tx = row.txid;
    if (_localEchoes.containsKey(tx)) return;
    _restoreLatest();
    messages = _snapshot();
    _reindex();
    final local = RoomMessageViewModel(
      id: tx,
      transactionId: tx,
      senderId: '',
      text: row.content,
      isOwn: true,
      timestamp: _localTimestampFor(row.createdAt),
      deliveryState: roomDeliveryStateOf(row.status),
    );
    final transport = adapter;
    _senders[tx] = () => transport is RoomOptimisticTextAdapter
        ? (transport as RoomOptimisticTextAdapter)
            .sendTextWithTransaction(row.content, tx)
        : adapter.sendText(row.content);
    _echoRevision++;
    _localEchoes[tx] = local;
    messages = [...messages, local];
    _publish();
  }

  /// 本地时间戳（恢复行用它保持原始顺序；不早于窗口内最后一条）。
  DateTime _localTimestampFor(DateTime createdAt) {
    final next = createdAt;
    final newest = newestMessage;
    if (newest != null && !next.isAfter(newest.timestamp)) {
      return newest.timestamp.add(const Duration(microseconds: 1));
    }
    return next;
  }

  /// 只有在"文本 + 正文非空 + 有持久化日志"时才进入 outbox。
  ///
  /// 图片/视频/语音/红包/转账各自带带外载荷（媒体字节、业务单号），
  /// 重放正文无法重建，因此不进 outbox；它们继续沿用原来的内存乐观路径。
  bool _tracksOutbox(RoomMessageViewModel local) =>
      _outboxJournal != null &&
      local.kind == RoomMessageKind.text &&
      !local.isFlashPhoto &&
      local.text.trim().isNotEmpty;

  /// 把一次派发结果写回 outbox（状态 + 失败原因）。
  ///
  /// 行还不存在时（例如互动门禁在建行前就拒绝、或纯内存路径早退）按结果
  /// **补建**一行：用户的原文不因为在本地被拒就丢失，重进会话仍能看到
  /// 「发送失败」并可手动重试。
  Future<void> _persistOutboxOutcome(
    String tx,
    RoomMessageViewModel local,
    RoomDeliveryState state, {
    required Object? error,
    OutboxMessage? outboxRow,
  }) async {
    final journal = _outboxJournal;
    if (journal == null || !_tracksOutbox(local)) return;
    try {
      final row = outboxRow ??
          await journal.findByTxid(tx) ??
          await journal.persist(
              txid: tx,
              content: local.text,
              status: outboxStatusOf(state));
      if (row == null) return;
      if (state == RoomDeliveryState.sent) {
        await journal.complete(row.localId);
      } else {
        await journal.settle(row.localId, outboxStatusOf(state),
            lastError: error?.toString());
      }
      outboxError = null;
    } catch (persistError) {
      // 持久化故障绝不改变消息的可见结果（可用性优先），但必须可见。
      outboxError = persistError;
    }
  }

  Future<String?> _dispatch(
    String tx,
    RoomMessageViewModel local, {
    OutboxMessage? outboxRow,
  }) async {
    // 乐观行创建时是 `local`；派发一真正开始就**同步**翻成 `sending`，
    // 行绝不会停在「未派发」外观上（`sendText` 的调用方无需 await 即可看到）。
    // `local` 与 `sending` 的呈现完全一致，因此这次内部迁移不再额外通知：
    // 一条本地消息仍然只产生一次可见发布（性能契约：sendText 只发一次通知）。
    final inFlight = local.deliveryState == RoomDeliveryState.sending
        ? local
        : local.copyWith(deliveryState: RoomDeliveryState.sending);
    if (!identical(inFlight, local) && _localEchoes.containsKey(tx)) {
      _echoRevision++;
      _localEchoes[tx] = inFlight;
      messages = _snapshot();
    }
    _inFlightTxids.add(tx);
    final journal = _outboxJournal;
    final tracks = _tracksOutbox(inFlight);
    OutboxMessage? row = outboxRow;
    try {
      // ① 先持久化：没有这一行就绝不派发。
      if (journal != null && tracks) {
        row ??= await journal.findByTxid(tx);
        row ??= await journal.persist(
            txid: tx,
            content: inFlight.text,
            status: OutboxStatus.queued);
        if (row != null) {
          // ② 原子认领：认领失败 = 这一行已被（别的派发者）认领或已送达，
          //    本次绝不再发一遍。
          final claimed = await journal.claim(row.localId);
          if (!claimed) {
            final current = await journal.findByTxid(tx);
            if (current?.status == OutboxStatus.sent) {
              _echoRevision++;
              _eventTransactions[tx] = tx;
              _localEchoes[tx] =
                  inFlight.copyWith(deliveryState: RoomDeliveryState.sent);
              _senders.remove(tx);
              messages = _snapshot();
              _publish();
              return null;
            }
            return null;
          }
        }
      }
      // ③ 派发。
      final eventId = await _senders[tx]!();
      if (_disposed) return null;
      _echoRevision++;
      _eventTransactions[eventId] = tx;
      if (_localEchoes.containsKey(tx)) {
        _localEchoes[tx] = inFlight.copyWith(
            id: eventId, deliveryState: RoomDeliveryState.sent);
      }
      _waitingNetworkIds.remove(tx);
      _senders.remove(tx);
      NotificationFeedback.shared.play(SoundType.messageSent);
      // ④ 服务端已确认：outbox 行记 sent 并移除（不保留正文副本）。
      await _persistOutboxOutcome(tx, inFlight, RoomDeliveryState.sent,
          error: null, outboxRow: row);
      messages = _snapshot();
      _publish();
      return eventId;
    } catch (error) {
      if (_disposed) return null;
      _echoRevision++;
      // 网络失败 → 等待发送（保留 sender/txid 供恢复后自动重发）；
      // 其余（服务端拒绝、无权限等）→ 终局 failed。
      final state = _noteFailure(tx, error);
      _localEchoes[tx] = inFlight.copyWith(deliveryState: state);
      await _persistOutboxOutcome(tx, inFlight, state,
          error: error, outboxRow: row);
    } finally {
      _inFlightTxids.remove(tx);
    }
    messages = _snapshot();
    _publish();
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    _inFlightTxids.clear();
    _recoveryManager?.state.removeListener(_handleNetworkStateChanged);
    _recoveryManager = null;
    _refreshDeadline?.cancel();
    if (_refreshFrame != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(_refreshFrame!);
    }
    adapter.dispose();
    super.dispose();
  }
}
