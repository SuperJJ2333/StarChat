/// 会话未读状态机（BUG 5）。
///
/// 规则（与需求一一对应）：
/// 1. `event.senderId == currentUserId` → **NEVER_INCREMENT_UNREAD**：
///    自己发送的消息永远不计入未读；
/// 2. 正在查看的 Room：任何新消息都返回 0，并由聊天页负责推进已读
///    回执（`timeline.setReadMarker` → `m.read`）；
/// 3. 未读禁止用 `lastEventId != lastReadEventId` 直接推断——服务器
///    `notificationCount` 是唯一增量来源，本地"已清零位点"只用于
///    **抑制**同步滞后期间的陈旧计数（方向：只可能把未读压成 0）；
/// 4. 自己发送成功后推进清零位点，unread 保持 0；
/// 5. 手动未读（`manualUnread`，来自房间偏好，持久化于本地设置）与
///    @高亮（`highlightCount`）作为独立维度暴露，不与未读数混算。
///
/// 实例通过 [shared] 在会话列表页与聊天页之间共享；重启后服务器
/// 计数与已读回执由 Matrix 同步恢复（需求 7/8 的持久化语义）。
final class ConversationReadState {
  ConversationReadState._internal();

  static final ConversationReadState _shared =
      ConversationReadState._internal();
  factory ConversationReadState.shared() => _shared;

  /// 测试隔离用：重置共享实例的本地状态。
  void resetForTest() {
    _openRooms.clear();
    _clearedEventByRoom.clear();
  }

  /// 正在查看（聊天页处于栈顶）的房间。
  final Set<String> _openRooms = {};

  /// 本地"已清零"位点：退出聊天页/自己发送时推进到的 eventId。
  final Map<String, String?> _clearedEventByRoom = {};

  void setRoomOpen(String roomId, {required bool open}) {
    open ? _openRooms.add(roomId) : _openRooms.remove(roomId);
  }

  bool isRoomOpen(String roomId) => _openRooms.contains(roomId);

  /// 推进本地"已清零"位点（打开页面/查看中收到新消息/自己发送成功）。
  void markCleared(String roomId, {required String? eventId}) {
    _clearedEventByRoom[roomId] = eventId;
  }

  int unreadCount({
    required String roomId,
    required int serverUnreadCount,
    required String? lastEventId,
    required String? lastEventSenderId,
    required String? currentUserId,
    bool manualUnread = false,
  }) {
    if (manualUnread) return 1; // 需求 6：手动标记未读优先展示
    if (_openRooms.contains(roomId)) return 0; // 需求 4：查看中恒为 0
    if (lastEventSenderId != null && lastEventSenderId == currentUserId) {
      return 0; // 需求 1/2：自己发送的消息 NEVER_INCREMENT_UNREAD
    }
    final cleared = _clearedEventByRoom[roomId];
    if (cleared != null && cleared == lastEventId) {
      return 0; // 同步滞后的陈旧服务器计数抑制（只压零，不增量）
    }
    return serverUnreadCount; // 需求 3/8：服务器权威计数（sync 收敛）
  }

  /// @高亮（`room.highlightCount`，m.highlight 语义）：查看中为 0。
  int highlightCount({
    required String roomId,
    required int roomHighlightCount,
  }) {
    if (_openRooms.contains(roomId)) return 0;
    return roomHighlightCount;
  }
}
