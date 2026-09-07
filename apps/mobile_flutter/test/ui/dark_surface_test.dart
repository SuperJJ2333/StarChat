import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/components/wechat_nav_title.dart';
import 'package:liuhetong_mobile/ui/components/auth_surface_card.dart';
import 'package:liuhetong_mobile/ui/components/wechat_scaffold.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';
import 'package:liuhetong_mobile/ui/theme/wechat_theme.dart';

void main() {
  testWidgets('auth error surface follows dark palette', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      theme: WeChatTheme.build(Brightness.dark),
      home: const WeChatPageScaffold.bare(
        child: AuthErrorMessage(message: '请重试'),
      ),
    ));
    final box =
        tester.widget<Container>(find.byKey(const Key('auth-error-message')));
    expect((box.decoration as BoxDecoration).color, const Color(0xFF331D1D));
  });
  testWidgets('root and secondary surfaces repaint on light dark light switch',
      (tester) async {
    for (final brightness in [
      Brightness.light,
      Brightness.dark,
      Brightness.light
    ]) {
      await tester.pumpWidget(CupertinoApp(
          theme: WeChatTheme.build(brightness),
          home: const WeChatPageScaffold(
              title: '页面',
              backgroundColor: WeChatColors.tabRootPageBackground,
              child: SizedBox.expand())));
      await tester.pumpAndSettle();
      final dark = brightness == Brightness.dark;
      final nav = tester
          .widget<CupertinoNavigationBar>(find.byType(CupertinoNavigationBar));
      expect(
          nav.backgroundColor,
          dark
              ? WeChatColors.darkSurface
              : WeChatColors.chatNavigationBackground);
      // Check the concrete page widget, not merely the application's theme.
      final page = tester
          .widget<CupertinoPageScaffold>(find.byType(CupertinoPageScaffold));
      expect(
          page.backgroundColor,
          dark
              ? WeChatColors.darkPageBackground
              : WeChatColors.lightPageBackground);
    }
  });

  testWidgets(
      'bare page background and fixed navigation title follow dark theme',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
        theme: WeChatTheme.build(Brightness.dark),
        home: const WeChatPageScaffold.bare(child: WeChatNavTitle('通讯录'))));
    final title = tester.widget<Text>(find.text('通讯录'));
    expect(title.style?.color, WeChatColors.darkTextPrimary);
    final page = tester
        .widget<CupertinoPageScaffold>(find.byType(CupertinoPageScaffold));
    expect(page.backgroundColor, WeChatColors.darkPageBackground);
  });
}
