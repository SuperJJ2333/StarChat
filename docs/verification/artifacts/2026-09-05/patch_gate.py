from pathlib import Path

p = Path('apps/mobile_flutter/lib/features/matrix/room_timeline_controller.dart')
raw = p.read_text(encoding='utf-8')

# 1) controller 注入门（构造参数）
ctor_old = "  RoomTimelineController({"
assert ctor_old in raw
raw = raw.replace(ctor_old,
    "  RoomTimelineController({\n    this.canSendNow,", 1)
field_anchor = "  final RoomTimelineAdapter adapter;"
assert field_anchor in raw
raw = raw.replace(field_anchor,
    field_anchor + """

  /// 规格§二/§三：互动权限门（非好友/拉黑 → 消息进入本地 failed，
  /// 绝不触达发送服务；UI 与服务层同一守卫）。
  final bool Function()? canSendNow;""", 1)

# 2) sendText：门禁 → 本地 failed（感叹号），不丢弃不假成功
old = """  Future<void> sendText(String text) async {
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
    try {"""
new = """  Future<void> sendText(String text) async {
    final transactionId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    // 规格§三：无互动权限 → 本地 failed（发送失败感叹号），不丢弃。
    final allowed = canSendNow?.call() ?? true;
    if (!allowed) {
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
    try {"""
assert old in raw, 'sendText anchor'
raw = raw.replace(old, new, 1)
p.write_text(raw, encoding='utf-8', newline='')
print('controller OK')

# 3) room_page：构造 controller 时注入门（好友在缓存=可发）
p = Path('apps/mobile_flutter/lib/features/matrix/room_page.dart')
raw = p.read_text(encoding='utf-8')
anchor = "RoomTimelineController("
assert anchor in raw
inject = """RoomTimelineController(
      // 规格§二：权限集中判定——发送路径的服务层守卫（UI 另行禁用
      // 输入，但此处是权威：删除好友/拉黑后消息必失败）。
      canSendNow: () => InteractionPermission.resolve(
        isFriend: _peerIsFriend(),
        isBlocked: false, // 拉黑名单接口接入前的保守值（服务侧已隔离）
      ).canSendMessage(),"""
raw = raw.replace(anchor, inject, 1)
# _peerIsFriend 帮手
helper_anchor = "  /// 规格§八：聊天详情页头像"
helper = """  /// 对端是否仍是好友（身份缓存权威；缓存未载时保守放行，
  /// 由发送层失败兜底——绝不禁用正常聊天）。
  bool _peerIsFriend() {
    final peers = widget.room.getParticipants()
        .where((m) => m.id != widget.matrix.sdkClient.userID)
        .toList(growable: false);
    if (peers.length != 1) return true; // 群聊不适用好友门
    final contact = _identityCache.contactsByMatrixId[peers.first.id];
    // 曾打开的会话但已删除好友：缓存查无此人 → 非好友。
    return contact != null;
  }

  /// 规格§八：聊天详情页头像"""
assert helper_anchor in raw
raw = raw.replace(helper_anchor, helper, 1)
if "interaction_permission.dart" not in raw:
    raw = raw.replace(
        "import 'direct_chat_controller.dart';",
        "import 'direct_chat_controller.dart';\n"
        "import '../../core/permissions/interaction_permission.dart';", 1)
p.write_text(raw, encoding='utf-8', newline='')
print('room_page OK')
