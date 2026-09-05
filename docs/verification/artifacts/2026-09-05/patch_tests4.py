from pathlib import Path

p = Path('apps/mobile_flutter/test/features/matrix/direct_chat_info_test.dart')
raw = p.read_text(encoding='utf-8')
old = """    // PRD §44：私聊信息页提供 默认/静音/特别关注 三态通知设置。
    expect(find.text('消息通知'), findsOneWidget);
    expect(find.text('特别关注'), findsOneWidget);
    expect(find.text('置顶聊天'), findsOneWidget);
    expect(find.text('保存到通讯录'), findsOneWidget);"""
new = """    // 规格§四：消息通知一级菜单默认收起——三态展开后出现。
    expect(find.text('消息通知'), findsOneWidget);
    expect(find.text('特别关注'), findsNothing, reason: '默认收起：三态不可见');
    expect(find.text('置顶聊天'), findsOneWidget);
    // 规格§五：私聊隐藏"保存到通讯录"（仅群聊显示）。
    expect(find.text('保存到通讯录'), findsNothing);"""
assert old in raw, 'info test anchor'
raw = raw.replace(old, new, 1)
assert raw.rstrip().endswith('}'), 'unexpected tail'
raw = raw.rstrip()
raw = raw[: raw.rfind('}')] + """
  testWidgets('规格§四：点击"消息通知"展开三态（默认/静音/特别关注）',
      (tester) async {
    await tester.pumpWidget(_buildInfoPage());
    await tester.tap(find.text('消息通知'));
    await tester.pumpAndSettle();
    expect(find.text('特别关注'), findsOneWidget);
    expect(find.text('静音'), findsOneWidget);
  });
}
"""
p.write_text(raw, encoding='utf-8', newline='')
print('info test OK')

p = Path('apps/mobile_flutter/test/features/matrix/direct_chat_service_test.dart')
raw = p.read_text(encoding='utf-8')
old = """      final openRoomStart = home.indexOf('Future<void> _openRoom(Room room)');
      final openRoomEnd = home.indexOf('Future<void> _warmChatIdentity');
      final body = home.substring(openRoomStart, openRoomEnd);"""
new = """      final openRoomStart = home.indexOf('Future<void> _openRoom(Room room)');
      final body = home.substring(
          openRoomStart, home.indexOf('await navigator.push(', openRoomStart));"""
assert old in raw, 'service test anchor'
p.write_text(raw.replace(old, new, 1), encoding='utf-8', newline='')
print('service test OK')
