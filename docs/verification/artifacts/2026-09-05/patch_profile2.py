from pathlib import Path

p = Path('apps/mobile_flutter/lib/features/matrix/room_page.dart')
raw = p.read_text(encoding='utf-8')

old = "        builder: (_) => DirectChatInfoPage("
new = """        builder: (_) => DirectChatInfoPage(
          // 规格§八：头像点击 → APP 好友资料页（非 Matrix Profile）。
          onTapPerson: (matrixUserId) =>
              unawaited(_openPeerProfile(matrixUserId)),
"""
assert old in raw, 'info usage anchor'
raw = raw.replace(old, new, 1)

anchor = "  Future<void> _openVideoViewer(RoomMessageViewModel message) async {"
helper = """  /// 规格§八：聊天详情页头像 → APP 自己的好友/用户资料页（禁止打开
  /// Matrix Profile）。好友直开；非好友走业务检索（同一 APP 页面）。
  Future<void> _openPeerProfile(String matrixUserId) async {
    final contact = _identityCache.contactsByMatrixId[matrixUserId];
    if (contact != null) {
      if (!mounted) return;
      await Navigator.of(context, rootNavigator: true).push(
        CupertinoPageRoute(
          builder: (_) => AddFriendProfilePage(
            api: widget.api,
            userId: contact.userId,
            username: contact.username,
            nickname: (contact.nickname?.isNotEmpty == true)
                ? contact.nickname!
                : contact.username,
            relationshipState: 'FRIEND',
            avatarUrl: contact.avatarUrl,
          ),
        ),
      );
      return;
    }
    // 非好友（已删除/陌生人）：沿用既有的按 Matrix ID 业务检索路径。
    await _openMemberProfileByMatrixId(matrixUserId);
  }

  Future<void> _openVideoViewer(RoomMessageViewModel message) async {"""
assert anchor in raw, 'video viewer anchor'
raw = raw.replace(anchor, helper, 1)
p.write_text(raw, encoding='utf-8', newline='')
print('room_page OK')
