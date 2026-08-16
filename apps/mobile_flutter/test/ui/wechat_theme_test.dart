import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/components/modern_action_button.dart';
import 'package:liuhetong_mobile/ui/foundation/changliao_icons.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';
import 'package:liuhetong_mobile/ui/theme/wechat_theme.dart';

void main() {
  test('light theme uses the approved WeChat palette', () {
    final theme = WeChatTheme.build(Brightness.light);
    expect(theme.primaryColor, const Color(0xFF07C160));
    expect(theme.scaffoldBackgroundColor, const Color(0xFFEDEDED));
  });
  test('dark theme uses a dark surface with light primary text', () {
    final theme = WeChatTheme.build(Brightness.dark);
    expect(theme.scaffoldBackgroundColor, const Color(0xFF111111));
    expect(theme.textTheme.textStyle.color, const Color(0xFFF5F5F5));
  });
  test('figma foundation exposes mobile geometry and semantic icons', () {
    expect(WeChatDimensions.screenWidth, 393);
    expect(WeChatDimensions.controlHeight, 48);
    expect(WeChatDimensions.minimumTouchTarget, 44);
    expect(WeChatRadius.authCard, 12);
    expect(WeChatRadius.authControl, 14);
    expect(ChangliaoIcons.messages, isA<IconData>());
    expect(ChangliaoIcons.contacts, isA<IconData>());
    expect(ChangliaoIcons.discover, isA<IconData>());
    expect(ChangliaoIcons.me, isA<IconData>());
    expect(ChangliaoIcons.voiceCall, isA<IconData>());
    expect(ChangliaoIcons.videoCall, isA<IconData>());
  });
  testWidgets('loading primary button cannot be pressed', (tester) async {
    var presses = 0;
    await tester.pumpWidget(
      CupertinoApp(
        home: ModernActionButton(
          icon: CupertinoIcons.person,
          label: '登录',
          loading: true,
          onPressed: () => presses++,
        ),
      ),
    );
    await tester.tap(find.text('登录'));
    expect(presses, 0);
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
  });
}
