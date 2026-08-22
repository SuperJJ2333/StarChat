import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_info_page.dart';

void main() {
  testWidgets('direct chat info exposes shared rows and omits group-only rows',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: DirectChatInfoPage(
        peerName: '安然',
        peerId: '@anran:test',
        matrixClient: Client('test')..homeserver = Uri.parse('https://matrix.example.test'),
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
    expect(find.text('消息免打扰'), findsOneWidget);
    expect(find.text('置顶聊天'), findsOneWidget);
    expect(find.text('保存到通讯录'), findsOneWidget);
    expect(find.text('清空聊天记录'), findsOneWidget);
    expect(find.text('群聊名称'), findsNothing);
    expect(find.text('群公告'), findsNothing);
    expect(find.text('退出群聊'), findsNothing);
  });
}
