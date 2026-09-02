import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_read_state.dart';

/// BUG 5 未读状态机的 8 个验收场景。
void main() {
  const me = '@me:test';
  const friend = '@friend:test';

  tearDown(() => ConversationReadState.shared().resetForTest());

  test('1/2. 自己在私聊/群聊发送消息 → 红点保持 0', () {
    final state = ConversationReadState.shared();
    state.setRoomOpen('!private:test', open: true);
    state.markCleared('!private:test', eventId: r'$echo');
    // 私聊：自己本地回显事件落在顶部。
    expect(
      state.unreadCount(
        roomId: '!private:test',
        serverUnreadCount: 2, // 服务器计数尚未收敛
        lastEventId: r'$echo',
        lastEventSenderId: me,
        currentUserId: me,
      ),
      0,
    );
    // 群聊：发送成功后退出聊天页（setRoomOpen false），仍为 0。
    state.setRoomOpen('!group:test', open: true);
    state.markCleared('!group:test', eventId: r'$g-echo');
    state.setRoomOpen('!group:test', open: false);
    expect(
      state.unreadCount(
        roomId: '!group:test',
        serverUnreadCount: 2,
        lastEventId: r'$g-echo',
        lastEventSenderId: me,
        currentUserId: me,
      ),
      0,
    );
  });

  test('3. 别人在后台发消息 → 未读增加（服务器权威计数）', () {
    final state = ConversationReadState.shared();
    state.markCleared('!room:test', eventId: r'$read');
    state.setRoomOpen('!room:test', open: false);
    expect(
      state.unreadCount(
        roomId: '!room:test',
        serverUnreadCount: 3, // sync 已把新消息计入 notificationCount
        lastEventId: r'$new',
        lastEventSenderId: friend,
        currentUserId: me,
      ),
      3,
    );
  });

  test('4. 当前正在查看 Room 时别人发消息 → 红点 0', () {
    final state = ConversationReadState.shared();
    state.setRoomOpen('!room:test', open: true);
    expect(
      state.unreadCount(
        roomId: '!room:test',
        serverUnreadCount: 5,
        lastEventId: r'$incoming',
        lastEventSenderId: friend,
        currentUserId: me,
      ),
      0,
    );
  });

  test('5. @当前用户 → highlightCount 正确（查看中归零，后台保留）', () {
    final state = ConversationReadState.shared();
    state.setRoomOpen('!open:test', open: true);
    expect(
      state.highlightCount(roomId: '!open:test', roomHighlightCount: 2),
      0,
    );
    expect(
      state.highlightCount(roomId: '!bg:test', roomHighlightCount: 2),
      2,
    );
  });

  test('6. 手动标记未读 → manualUnread 正常展示', () {
    final state = ConversationReadState.shared();
    expect(
      state.unreadCount(
        roomId: '!room:test',
        serverUnreadCount: 0,
        lastEventId: r'$e',
        lastEventSenderId: me,
        currentUserId: me,
        manualUnread: true,
      ),
      1,
    );
  });

  test('7. 重新启动 APP → 未读状态保持正确', () {
    // 重启后本地清零位点清空，服务器计数（sync 恢复）为唯一事实来源；
    // 自己消息规则基于 senderId 判定，跨重启保持。
    final fresh = ConversationReadState.shared();
    fresh.resetForTest();
    expect(
      fresh.unreadCount(
        roomId: '!room:test',
        serverUnreadCount: 4,
        lastEventId: r'$last',
        lastEventSenderId: friend,
        currentUserId: me,
      ),
      4,
    );
    expect(
      fresh.unreadCount(
        roomId: '!room2:test',
        serverUnreadCount: 1,
        lastEventId: r'$mine',
        lastEventSenderId: me,
        currentUserId: me,
      ),
      0,
    );
  });

  test('8. 多设备同步 Read Receipt → 未读随服务器计数收敛', () {
    final state = ConversationReadState.shared();
    state.markCleared('!room:test', eventId: r'$read');
    // 另一台设备已读：服务器 notificationCount 归零 → 本地未读归零。
    expect(
      state.unreadCount(
        roomId: '!room:test',
        serverUnreadCount: 0,
        lastEventId: r'$read',
        lastEventSenderId: friend,
        currentUserId: me,
      ),
      0,
    );
    // 本地清零位点同样抑制同步滞后（服务器还显示 2，但位点已是最新）。
    expect(
      state.unreadCount(
        roomId: '!room:test',
        serverUnreadCount: 2,
        lastEventId: r'$read',
        lastEventSenderId: friend,
        currentUserId: me,
      ),
      0,
    );
  });

  test('回归：进入房间立即清零既有红点（既有行为保持）', () {
    final state = ConversationReadState.shared();
    state.setRoomOpen('!room:test', open: true);
    state.markCleared('!room:test', eventId: r'$before');
    state.setRoomOpen('!room:test', open: false);
    expect(
      state.unreadCount(
        roomId: '!room:test',
        serverUnreadCount: 3,
        lastEventId: r'$before',
        lastEventSenderId: friend,
        currentUserId: me,
      ),
      0,
    );
  });
}
