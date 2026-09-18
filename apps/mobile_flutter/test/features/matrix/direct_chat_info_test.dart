import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_info_page.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_user_avatar.dart';
import 'package:liuhetong_mobile/features/matrix/avatar_url_resolver.dart';
import 'package:liuhetong_mobile/ui/components/wechat_list_tile.dart';

final class _FakeAvatarMedia implements AvatarMediaCapability {
  @override
  Future<ResolvedAvatarUrl?> resolveAvatar({
    required Uri? avatarUri,
    required double size,
  }) async =>
      null;
}

void main() {
  testWidgets('direct chat info exposes shared rows and omits group-only rows',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: DirectChatInfoPage(
        peerName: '安然',
        peerId: '@anran:test',
        avatarMedia: _FakeAvatarMedia(),
        preference: const ConversationPreference(),
        onAddMember: () {},
        onSearchHistory: () {},
        onClearLocalHistory: () async {},
        onPreferenceChanged: (_) async {},
      ),
    ));
    expect(find.text('聊天信息'), findsOneWidget);
    expect(find.text('添加'), findsOneWidget);
    expect(find.text('查找聊天记录'), findsOneWidget);
    expect(find.text('设置拍一拍'), findsNothing);
    // 规格§四：消息通知一级菜单默认收起——三态展开后出现。
    expect(find.text('消息通知'), findsOneWidget);
    expect(find.text('特别关注'), findsNothing, reason: '默认收起：三态不可见');
    expect(find.text('置顶聊天'), findsOneWidget);
    // 规格§五：私聊隐藏"保存到通讯录"（仅群聊显示）。
    expect(find.text('保存到通讯录'), findsNothing);
    expect(find.text('清空聊天记录'), findsOneWidget);
    expect(find.text('群聊名称'), findsNothing);
    expect(find.text('群公告'), findsNothing);
    expect(find.text('退出群聊'), findsNothing);
  });

  testWidgets('聊天信息页「清空聊天记录」文字居中', (tester) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CupertinoApp(
      home: DirectChatInfoPage(
        peerName: '安然',
        peerId: '@anran:test',
        avatarMedia: _FakeAvatarMedia(),
        preference: const ConversationPreference(),
        onAddMember: () {},
        onSearchHistory: () {},
        onClearLocalHistory: () async {},
        onPreferenceChanged: (_) async {},
      ),
    ));
    final label = find.text('清空聊天记录');
    // 行容器由共享的 WeChatListTile 提供（2026-09-18 起不再委托
    // CupertinoListTile：后者的 spaceBetween 内容列会把文案顶到行边）。
    final row = find.ancestor(of: label, matching: find.byType(WeChatListTile));
    expect(row, findsOneWidget);
    expect(
        (tester.getCenter(label).dx - tester.getCenter(row).dx).abs(),
        lessThan(1.0),
        reason: '「清空聊天记录」文字必须相对所在行居中，而非左对齐');
  });

  testWidgets('规格§四：点击"消息通知"展开三态（默认/静音/特别关注）', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: DirectChatInfoPage(
        peerName: '安然',
        peerId: '@anran:test',
        avatarMedia: _FakeAvatarMedia(),
        preference: const ConversationPreference(),
        onAddMember: () {},
        onSearchHistory: () {},
        onClearLocalHistory: () async {},
        onPreferenceChanged: (_) async {},
      ),
    ));
    await tester.tap(find.text('消息通知'));
    await tester.pumpAndSettle();
    expect(find.text('特别关注'), findsOneWidget);
    expect(find.text('静音'), findsOneWidget);
  });
}
