from pathlib import Path

p = Path('apps/mobile_flutter/lib/features/matrix/room_timeline_controller.dart')
raw = p.read_text(encoding='utf-8')
old = """  Future<void> sendText(String text) async {
    final transactionId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    messages = ["""
new = """  Future<void> sendText(String text) async {
    final transactionId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    // 规格§三：无互动权限 → 本地 failed（发送失败感叹号），不丢弃
    // 不假成功，也绝不触达发送服务。
    if (!(canSendNow?.call() ?? true)) {
      messages = [
        ...messages,
        RoomMessageViewModel(
          id: transactionId,
          senderId: '',
          text: text,
          isOwn: true,
          deliveryState: RoomDeliveryState.failed,
          timestamp: DateTime.now(),
        ),
      ];
      notifyListeners();
      return;
    }
    messages = ["""
assert old in raw, 'sendText anchor'
p.write_text(raw.replace(old, new, 1), encoding='utf-8', newline='')
print('sendText gate OK')

# room_page：controller 注入门 + _peerIsFriend 帮手 + import
p = Path('apps/mobile_flutter/lib/features/matrix/room_page.dart')
raw = p.read_text(encoding='utf-8')
if 'canSendNow: () => InteractionPermission' not in raw:
    anchor = 'RoomTimelineController('
    inject = """RoomTimelineController(
      // 规格§二：服务层权威权限门（UI 之外的第二道，删除好友/拉黑后
      // 发送必失败，消息进入本地 failed 状态）。
      canSendNow: () => InteractionPermission.resolve(
        isFriend: _peerIsFriend(),
        isBlocked: false, // 拉黑名单接口接入前保守值（服务侧已隔离）
      ).canSendMessage(),"""
    assert anchor in raw, 'controller ctor anchor'
    raw = raw.replace(anchor, inject, 1)
    helper_anchor = "  /// 规格§八：聊天详情页头像"
    helper = """  /// 对端是否仍是好友（身份缓存权威；群聊不适用此门）。
  bool _peerIsFriend() {
    final selfId = widget.matrix.sdkClient.userID;
    final peers = widget.room
        .getParticipants()
        .where((m) => m.id != selfId)
        .toList(growable: false);
    if (peers.length != 1) return true; // 群聊/异常：放行（群权限另有体系）
    // 曾打开的会话但已删除好友：身份缓存查无此人 → 非好友。
    return _identityCache.contactsByMatrixId[peers.first.id] != null;
  }

  /// 规格§八：聊天详情页头像"""
    assert helper_anchor in raw, 'helper anchor'
    raw = raw.replace(helper_anchor, helper, 1)
    raw = raw.replace(
        "import 'direct_chat_controller.dart';",
        "import 'direct_chat_controller.dart';\n"
        "import '../../core/permissions/interaction_permission.dart';", 1)
    p.write_text(raw, encoding='utf-8', newline='')
print('room_page gate OK')
