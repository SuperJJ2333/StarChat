import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/components/modern_action_button.dart';
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
  testWidgets('loading primary button cannot be pressed', (tester) async {
    var presses = 0;
    await tester.pumpWidget(CupertinoApp(
        home: ModernActionButton(
            icon: CupertinoIcons.person,
            label: '登录',
            loading: true,
            onPressed: () => presses++)));
    await tester.tap(find.text('登录'));
    expect(presses, 0);
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
  });
}
