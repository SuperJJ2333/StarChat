import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/components/wechat_nav_title.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';
import 'package:liuhetong_mobile/ui/theme/wechat_theme.dart';

/// Mimics the app's real bars: the messages tab root (WeChatNavTitle middle +
/// icon trailing) and a pushed page (plain Text middle, automatic back chevron).
Widget _messagesTab(VoidCallback onSearch) => CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.chatNavigationBackground,
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: const WeChatNavTitle('消息'),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          CupertinoButton(
            key: const Key('open-search'),
            padding: EdgeInsets.zero,
            onPressed: onSearch,
            child: const Icon(CupertinoIcons.search, size: 22),
          ),
        ]),
      ),
      child: Container(),
    );

Widget _searchPage() => CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.chatNavigationBackground,
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: const Text('搜索'),
      ),
      child: Container(),
    );

Widget _app({required Widget home, GlobalKey<NavigatorState>? navigatorKey}) =>
    CupertinoApp(
      navigatorKey: navigatorKey,
      theme: WeChatTheme.build(Brightness.light),
      home: home,
    );

void main() {
  testWidgets(
      'pushing the search page from the messages tab keeps the nav bar hero '
      'flight free of TextStyle interpolation errors', (tester) async {
    await tester.pumpWidget(_app(
      home: Builder(
        builder: (context) => _messagesTab(() => Navigator.of(context).push(
              CupertinoPageRoute<void>(builder: (_) => _searchPage()),
            )),
      ),
    ));
    await tester.pump();

    await tester.tap(find.byKey(const Key('open-search')));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'popping back from a pushed page keeps the flight exception-free',
      (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(_app(
      navigatorKey: navigatorKey,
      home: Builder(
        builder: (context) => _messagesTab(() => Navigator.of(context).push(
              CupertinoPageRoute<void>(builder: (_) => _searchPage()),
            )),
      ),
    ));
    await tester.pump();

    await tester.tap(find.byKey(const Key('open-search')));
    await tester.pumpAndSettle();

    navigatorKey.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
