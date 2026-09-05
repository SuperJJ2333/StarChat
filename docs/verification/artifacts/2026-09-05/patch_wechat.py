from pathlib import Path

root = Path('apps/mobile_flutter')
ok = []

# ── A) adapter：私聊绝不产生"邀请加入群聊"通知（规格§一4）──────────
p = root / 'lib/features/matrix/matrix_room_timeline_adapter.dart'
raw = p.read_text(encoding='utf-8')
old = """    final notices = deriveGroupJoinNotices("""
new = """    // 规格§一4：私聊（m.direct）房间绝不推导群聊系统通知——DM 的
    // invite/join 成员事件属建房信令，不是"邀请加入群聊"。
    final notices = room.isDirectChat
        ? const <GroupJoinNotice>[]
        : deriveGroupJoinNotices("""
assert old in raw and 'room.isDirectChat\n        ? const' not in raw
raw = raw.replace(old, new, 1)
if 'group_join_notices.dart' in raw and 'GroupJoinNotice' in raw:
    pass
p.write_text(raw, encoding='utf-8', newline='')
ok.append('A adapter')

# ── B) matrix_home_page：先 push 再后台预取（规格§七）──────────────
p = root / 'lib/features/matrix/matrix_home_page.dart'
raw = p.read_text(encoding='utf-8')
old = """      try {
        await _identityCache.preload();
      } catch (_) {
        // Preserve the last successful identity snapshot and keep the
        // encrypted room route available when business identity refresh fails.
      }
      if (!mounted) return;
      await _identityCache.precacheAvatarImages(context);
      if (!mounted) return;
      final roomName = room.isDirectChat"""
new = """      // 规格§七（P0）：打开聊天页绝不等待身份预载/头像预解码——
      // 先用本地已有数据渲染，资料与头像在后台补齐（原实现在此处
      // 串行 await preload + precache，正是"点开聊天等 5 秒"的根因）。
      unawaited(_warmChatIdentity(context));
      final roomName = room.isDirectChat"""
assert old in raw, 'home openRoom anchor'
raw = raw.replace(old, new, 1)
helper_anchor = "  Future<void> _openRoom(Room room) async {"
helper = """  /// 聊天页后台预热（身份快照 + 头像解码；失败不影响已打开的会话）。
  Future<void> _warmChatIdentity(BuildContext context) async {
    try {
      await _identityCache.preload();
      if (!mounted) return;
      await _identityCache.precacheAvatarImages(context);
    } catch (_) {
      // 保留上一次成功快照；页面内自身会重试资料刷新。
    }
  }

  Future<void> _openRoom(Room room) async {"""
raw = raw.replace(helper_anchor, helper, 1)
p.write_text(raw, encoding='utf-8', newline='')
ok.append('B home-push-first')

# ── C) direct_chat_info_page：§四折叠 / §五隐藏保存 / §六居中 / §八头像跳转
p = root / 'lib/features/matrix/direct_chat_info_page.dart'
raw = p.read_text(encoding='utf-8')
# §四：三态平铺 → 一级菜单默认收起
old = """            ConversationNotificationModeTile(
              muted: preference.muted,
              attention: preference.attention,
              onChanged: (mode) => _update(preference.copyWith(
                muted: mode == ConversationNotificationMode.muted,
                attention: mode == ConversationNotificationMode.attention,
              )),
            ),"""
new = """            // 规格§四：一级菜单"消息通知 >"默认收起，点开再选三态。
            _notificationSection(),"""
assert old in raw, 'info notification anchor'
raw = raw.replace(old, new, 1)
# §五：私聊隐藏"保存到通讯录"（仅 Group 房间显示——群详情页保留）。
old = """            _switch('保存到通讯录', preference.saved,
                (value) => _update(preference.copyWith(saved: value))),
"""
assert old in raw, 'info saved anchor'
raw = raw.replace(old, '', 1)
# §六：清空聊天记录水平居中（Center，不用 padding 模拟）。
old = """            WeChatListTile(
              title: const Text(
                '清空聊天记录',
                style: TextStyle(color: WeChatColors.danger),
              ),
              onTap: _clear,
            ),"""
new = """            Center(
              child: WeChatListTile(
                title: const Text(
                  '清空聊天记录',
                  style: TextStyle(color: WeChatColors.danger),
                ),
                onTap: _clear,
              ),
            ),"""
assert old in raw, 'info clear anchor'
raw = raw.replace(old, new, 1)
# §八：私聊头像点击 → 好友资料页（回调注入，禁止打开 Matrix Profile）。
old = "  Widget _person(String name, String id, String? avatarUrl) =>\n      Column("
new = """  Widget _person(String name, String id, String? avatarUrl) =>
      GestureDetector(
        // 规格§八：点击头像进入 APP 自己的好友资料页（onTapPerson 由
        // RoomPage 注入，携带 userId；禁止打开 Matrix Profile）。
        onTap: () => widget.onTapPerson?.call(id),
        child: _personColumn(name, id, avatarUrl),
      );

  Widget _personColumn(String name, String id, String? avatarUrl) =>
      Column("""
assert old in raw, 'info person anchor'
raw = raw.replace(old, new, 1)
# 折叠组件 + onTapPerson 字段
ctor_anchor = "final class DirectChatInfoPage extends StatefulWidget {"
ctor_new = """final class DirectChatInfoPage extends StatefulWidget {
  const DirectChatInfoPage({
    super.key,
    this.onTapPerson,
  });

  /// 规格§八：好友头像点击（参数 userId）→ 好友资料页。
  final void Function(String userId)? onTapPerson;
"""
assert ctor_anchor in raw
raw = raw.replace(ctor_anchor, ctor_new, 1)
# 折叠实现方法（插到 _person 前）
section_anchor = "  Widget _person(String name, String id, String? avatarUrl) =>"
section = """  bool _notificationExpanded = false;

  Widget _notificationSection() {
    final mode = preference.muted
        ? ConversationNotificationMode.muted
        : preference.attention
            ? ConversationNotificationMode.attention
            : ConversationNotificationMode.normal;
    final modeLabel = switch (mode) {
      ConversationNotificationMode.muted => '静音',
      ConversationNotificationMode.attention => '特别关注',
      _ => '默认',
    };
    return Column(children: [
      WeChatListTile(
        title: const Text('消息通知'),
        additionalInfo: Text(modeLabel),
        trailing: const CupertinoListTileChevron(),
        onTap: () => setState(() => _notificationExpanded = !_notificationExpanded),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 200),
        alignment: Alignment.topCenter,
        child: _notificationExpanded
            ? ConversationNotificationModeTile(
                muted: preference.muted,
                attention: preference.attention,
                onChanged: (m) {
                  setState(() => _notificationExpanded = false);
                  _update(preference.copyWith(
                    muted: m == ConversationNotificationMode.muted,
                    attention: m == ConversationNotificationMode.attention,
                  ));
                },
              )
            : const SizedBox(width: double.infinity),
      ),
    ]);
  }

  Widget _person(String name, String id, String? avatarUrl) =>"""
assert section_anchor in raw
raw = raw.replace(section_anchor, section, 1)
p.write_text(raw, encoding='utf-8', newline='')
ok.append('C info-page')

print('; '.join(ok))
