import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/moments/moment_models.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_tile.dart';

void main() {
  final item = MomentItem.fromJson({
    'id': 'm1',
    'author': {'user_id': 'u1', 'username': 'alice', 'nickname': '小爱'},
    'text': '第一行\n第二行 😊',
    'created_at': '2026-09-09T08:00:00Z',
    'image_urls': [],
    'comments': [
      {
        'id': 'c1',
        'text': '回复',
        'author': {'user_id': 'u2', 'username': 'bob'},
      }
    ],
  });
  testWidgets('long press copies exact text and hides delete for others',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(CupertinoApp(home: WeChatMomentTile(item: item)));
    await tester.longPress(find.text(item.text));
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('删除'), findsNothing);
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(copied, item.text);
  });
  testWidgets(
      'author menu deletes via callback and preserves avatar/comment taps',
      (tester) async {
    var deletes = 0, avatars = 0, replies = 0;
    await tester.pumpWidget(CupertinoApp(
        home: WeChatMomentTile(
      item: item,
      onDelete: () => deletes++,
      onAuthorTap: () => avatars++,
      onCommentTap: (_) => replies++,
    )));
    await tester.tap(find.byType(UserAvatar).first);
    await tester.tap(find.byKey(const ValueKey('moment-comment-c1')));
    expect(avatars, 1);
    expect(replies, 1);
    await tester.longPress(find.text(item.text));
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(deletes, 1);
  });
}
