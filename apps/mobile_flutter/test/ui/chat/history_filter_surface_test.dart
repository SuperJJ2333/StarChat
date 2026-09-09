import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/chat_search_page.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';

void main() {
  testWidgets(
      'history filters use readable light surface and independent selection',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
        home: ChatSearchPage(
      isGroup: true,
      search: (f, {cursor, limit = 50}) async => [],
      memberEntries: const [],
      onJumpToMessage: (_) {},
    )));
    CupertinoButton button(String key) =>
        tester.widget<CupertinoButton>(find.descendant(
            of: find.byKey(Key(key)), matching: find.byType(CupertinoButton)));
    expect(button('chat-search-filter-file').color, WeChatColors.lightElevated);
    await tester.tap(find.byKey(const Key('chat-search-filter-media')));
    await tester.pumpAndSettle();
    expect(button('chat-search-filter-file').color, WeChatColors.lightElevated);
    expect(button('chat-search-filter-date').color, WeChatColors.lightElevated);
    final label = tester.widget<Text>(find.text('图片与视频').first);
    expect(label.style!.color, WeChatColors.lightTextPrimary);
  });
}
