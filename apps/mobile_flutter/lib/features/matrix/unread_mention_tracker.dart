import 'dart:convert';

/// 未读 @ 状态机（规格 #2）：账号 + 房间 + 事件 ID 维护"尚未查看的
/// 提及集合"，与普通已读数分开；按房间时间线**从新到旧**排序。
///
/// 判定规则：
/// - 依据解密后的**结构化提及目标**（m.mentions / 富文本 pill 的目标
///   userId 集合）判断是否包含当前用户；不凭昵称或正文出现 @ 判断；
/// - 本人发送、已撤回、已删除不计入；
/// - @所有人：发送时本人属于提醒范围（群成员且非本人发送）则计入；
/// - 初次建立本地状态：以**原有已读位置**为历史边界，此后的新提及
///   加入；旧消息重新解密不重复加入；
/// - 普通已读回执向后推进**不清空**未查看 @（只有可见性判定清除）；
/// - 本期为设备本地逐条查看状态，不做跨设备同步声明。
final class UnreadMentionTracker {
  UnreadMentionTracker({required this.accountId, required this.roomId});

  final String accountId;
  final String roomId;

  /// eventId → 时间线序号（用于从新到旧排序；不用可能异常的发送时间）。
  /// order 越大越新。
  final Map<String, int> _orderByEventId = <String, int>{};
  final Set<String> _pendingEventIds = <String>{};

  /// R9 修复：已查看事件集合——重复同步/恢复后，已查看的提及不再
  /// "复活"为未读。与 pending 一起持久化。
  final Set<String> _viewedEventIds = <String>{};

  /// 历史边界（初次建立的已读位置 order；用于排除"很久以前"的旧提及
  /// 回填）。与普通已读回执推进区分（R9：回执不替代逐条查看）。
  int _historyBoundaryOrder = -1;
  bool _initialized = false;

  int get pendingCount => _pendingEventIds.length;
  bool get hasPending => _pendingEventIds.isNotEmpty;

  /// 初始化历史边界（登录会话恢复时调用一次；R9：与回执推进分离）。
  void initializeBoundary({required int lastReadOrder}) {
    if (_initialized) return;
    _initialBoundaryOrder = lastReadOrder;
    _historyBoundaryOrder = lastReadOrder;
    _initialized = true;
  }

  /// 初始化边界（不可被回执推进覆盖）。
  int _initialBoundaryOrder = -1;

  /// 同步到达一条消息的提及判定。
  ///
  /// [order] 房间时间线序号（单调递增）；[senderIsSelf] 本人发送；
  /// [mentionedUserIds] 结构化提及目标集合（@所有人展开后的成员 ID）；
  /// [redactedOrDeleted] 已撤回/删除。
  /// 返回是否新加入待查看集合。
  bool onMessageArrived({
    required String eventId,
    required int order,
    required bool senderIsSelf,
    required Set<String> mentionedUserIds,
    bool redactedOrDeleted = false,
  }) {
    if (redactedOrDeleted || senderIsSelf) return false;
    if (!mentionedUserIds.contains(accountId)) return false;
    // R9：已查看过的事件，重复同步/恢复后不再复活为未读。
    if (_viewedEventIds.contains(eventId)) return false;
    // 历史边界：**初始化**时确立的边界之前的旧提及不加（回填防护）。
    // 普通已读回据推进（onReadReceiptAdvanced）不收窄此判定——
    // 规则："普通已读不替代逐条查看"。
    if (_initialized && order <= _initialBoundaryOrder) return false;
    _orderByEventId[eventId] = order;
    return _pendingEventIds.add(eventId);
  }

  /// 撤回/删除：从待查看集合移除。
  void onRedacted(String eventId) {
    _pendingEventIds.remove(eventId);
  }

  /// 待查看列表：按时间线从新到旧（order 降序）。
  List<String> pendingEventIdsNewestFirst() {
    final entries = _pendingEventIds.toList()
      ..sort((a, b) => (_orderByEventId[b] ?? 0).compareTo(_orderByEventId[a] ?? 0));
    return entries;
  }

  /// 下一条跳转目标（最新的未查看提及；null = 无）。
  String? get nextJumpTarget =>
      pendingEventIdsNewestFirst().firstOrNull;

  /// 可见性判定通过（气泡 ≥50% 可见持续 500ms 且应用前台）：标记已查看。
  /// R9：同时记录到已查看集合（重复同步/恢复后不复活）。
  bool markViewed(String eventId) {
    _viewedEventIds.add(eventId);
    return _pendingEventIds.remove(eventId);
  }

  /// 跳转失败：不消费该条（保留在集合中供重试）。
  void onJumpFailed(String eventId) {
    // 不移除：记录重试提示由 UI 层处理。
  }

  /// 普通已读回执推进：R9 修复——回执不再收窄提及加入判定
  /// （"普通已读不替代逐条查看"）；仅推进边界用于诊断。
  void onReadReceiptAdvanced({required int order}) {
    if (order > _historyBoundaryOrder) _historyBoundaryOrder = order;
  }

  /// 持久化序列化（账号隔离本地存储用；含已查看集合——R9）。
  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'roomId': roomId,
        'pending': _pendingEventIds.toList(growable: false),
        'viewed': _viewedEventIds.toList(growable: false),
        'orders': {
          for (final entry in _orderByEventId.entries)
            entry.key: entry.value,
        },
        'boundary': _historyBoundaryOrder,
        'initialBoundary': _initialBoundaryOrder,
        'initialized': _initialized,
      };

  static UnreadMentionTracker fromJson(Map<String, dynamic> json) {
    final tracker = UnreadMentionTracker(
      accountId: json['accountId'] as String,
      roomId: json['roomId'] as String,
    );
    for (final id in (json['pending'] as List).cast<String>()) {
      tracker._pendingEventIds.add(id);
    }
    // R9：恢复已查看集合。
    for (final id in ((json['viewed'] as List?) ?? const []).cast<String>()) {
      tracker._viewedEventIds.add(id);
    }
    final orders = json['orders'] as Map<String, dynamic>;
    for (final entry in orders.entries) {
      tracker._orderByEventId[entry.key] = entry.value as int;
    }
    tracker._historyBoundaryOrder = (json['boundary'] as num?)?.toInt() ?? -1;
    tracker._initialBoundaryOrder =
        (json['initialBoundary'] as num?)?.toInt() ?? tracker._historyBoundaryOrder;
    tracker._initialized = json['initialized'] as bool? ?? false;
    return tracker;
  }

  String encode() => jsonEncode(toJson());

  static UnreadMentionTracker? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return UnreadMentionTracker.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

/// 会话摘要前缀（规格 #2）：红色 [有人@你] + 原摘要，独立文本片段，
/// 不替换/覆盖原内容；原摘要仍可正常省略。
(String prefix, String rest) mentionPrefixForSummary({
  required bool hasPendingMention,
  required String originalSummary,
}) {
  if (!hasPendingMention) return ('', originalSummary);
  return ('[有人@你] ', originalSummary);
}
