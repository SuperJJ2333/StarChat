from pathlib import Path

root = Path('apps/mobile_flutter')

# ── room_page：信息页注入 onTapPerson（§八）─────────────────────────
p = root / 'lib/features/matrix/room_page.dart'
raw = p.read_text(encoding='utf-8')
old = "        builder: (_) => DirectChatInfoPage("
new = """        builder: (_) => DirectChatInfoPage(
          // 规格§八：头像点击 → APP 好友资料页（非 Matrix Profile）。
          onTapPerson: _openPeerProfileById,
"""
assert old in raw, 'info usage anchor'
raw = raw.replace(old, new, 1)

# _openPeerProfileById：按 matrixUserId 打开好友资料（复用既有 lookup 页）。
anchor = "  Future<void> _openContact(ContactDetails contact) async {"
helper = """  /// 规格§八：聊天详情页头像 → 好友资料页（禁止打开 Matrix Profile）。
  Future<void> _openPeerProfileById(String matrixUserId) async {
    final contact = _identityCache.contactsByMatrixId[matrixUserId];
    if (contact != null) {
      final details = ContactDetails(
        matrixUserId: contact.matrixUserId,
        displayName: contact.remark?.isNotEmpty == true
            ? contact.remark!
            : (contact.nickname?.isNotEmpty == true
                ? contact.nickname!
                : contact.username),
        username: contact.username,
        avatarUrl: contact.avatarUrl,
      );
      if (!mounted) return;
      await Navigator.of(context, rootNavigator: true).push(
        CupertinoPageRoute(
          builder: (_) => AddFriendProfilePage(
            api: widget.api,
            userId: contact.userId,
            username: contact.username,
            nickname: contact.nickname ?? contact.username,
            matrixUserId: contact.matrixUserId,
            isFriend: true,
          ),
        ),
      );
      return;
    }
    // 非好友（已删除/陌生人）：按 Matrix 用户检索资料页（同一 APP 页面）。
    final member = await widget.matrix.sdkClient
        .getRoomById(widget.room.id)
        ?.unsafeGetUserFromMemoryOrFallback(matrixUserId)
        .requestProfile();
    if (!mounted) return;
    await Navigator.of(context, rootNavigator: true).push(
      CupertinoPageRoute(
        builder: (_) => AddFriendProfilePage(
          api: widget.api,
          userId: matrixUserId,
          username: matrixUserId.split(':').first.replaceFirst('@', ''),
          nickname: member.displayname ?? matrixUserId,
          matrixUserId: matrixUserId,
          isFriend: false,
        ),
      ),
    );
  }

  Future<void> _openContact(ContactDetails contact) async {"""
assert anchor in raw, 'contact anchor'
raw = raw.replace(anchor, helper, 1)
p.write_text(raw, encoding='utf-8', newline='')
print('room_page OK')
