import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/profile/my_qr_code_page.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/features/contacts/friend_qr.dart';
import 'package:liuhetong_mobile/ui/chat/chat_more_panel.dart';
import 'package:liuhetong_mobile/ui/chat/chat_tools.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('好友二维码载荷（friend_qr）', () {
    test('build/parse roundtrip', () {
      final payload = buildFriendQrPayload('alice');
      expect(payload, 'changliao://u/alice');
      expect(parseFriendQrPayload(payload), 'alice');
    });

    test('accepts bare changliao id', () {
      expect(parseFriendQrPayload('alice_01'), 'alice_01');
    });

    test('rejects unrelated urls and invalid ids', () {
      expect(parseFriendQrPayload('https://example.com/invite?x=1'), isNull);
      expect(parseFriendQrPayload('weixin://dl/business'), isNull);
      expect(parseFriendQrPayload('changliao://u/1a'), isNull);
      expect(parseFriendQrPayload(''), isNull);
    });
  });

  group('我的二维码页', () {
    testWidgets('renders nickname, qr image and scan hint', (tester) async {
      const profile = ProfileData(
        username: 'alice',
        nickname: '小艾',
        maskedEmail: 'a***@example.test',
        fallbackSeed: 'alice',
      );
      await tester.pumpWidget(
        const CupertinoApp(home: MyQrCodePage(profile: profile)),
      );

      expect(find.byKey(const Key('my-qr-image')), findsOneWidget);
      expect(find.byKey(const Key('my-qr-hint')), findsOneWidget);
      expect(find.text('小艾'), findsOneWidget);
      expect(find.text('扫一扫上面的二维码图案，加我为朋友'), findsOneWidget);
      expect(find.text('畅聊号：alice'), findsOneWidget);
    });
  });

  group('「更多」面板 → 工具 → 统计助手（需求 4 链路）', () {
    testWidgets('more panel tools cell triggers onTools', (tester) async {
      var toolsOpened = false;
      await tester.pumpWidget(CupertinoApp(
        home: CupertinoPageScaffold(
          child: Center(
            child: ChatMorePanel(
              onSelected: (_) {},
              onCameraLongPress: null,
              onTools: () => toolsOpened = true,
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const Key('chat-more-tools')));
      expect(toolsOpened, isTrue);
    });

    testWidgets('tools panel lists registered tool and routes taps',
        (tester) async {
      var toolTapped = false;
      ChatToolRegistry.clear();
      ChatToolRegistry.register(ChatTool(
        id: 'statistics_assistant',
        name: '统计助手',
        icon: CupertinoIcons.chart_bar,
        onTap: () => toolTapped = true,
      ));
      await tester.pumpWidget(CupertinoApp(
        home: CupertinoPageScaffold(
          child: Center(
            child: SizedBox(
              height: 232,
              child: ChatToolsPanel(
                onToolSelected: (tool) => tool.onTap(),
              ),
            ),
          ),
        ),
      ));
      expect(find.text('统计助手'), findsOneWidget);
      await tester.tap(find.text('统计助手'));
      expect(toolTapped, isTrue);
      ChatToolRegistry.clear();
    });
  });
}
