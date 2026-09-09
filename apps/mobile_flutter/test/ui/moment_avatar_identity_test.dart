import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/moments/moment_models.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_tile.dart';

void main() {
  testWidgets('Moments author uses the same avatar cache identity as contacts',
      (tester) async {
    final item = MomentItem.fromJson({
      'id': 'post',
      'text': 'Synthetic',
      'created_at': '2026-09-09T00:00:00Z',
      'author': {
        'user_id': 'business-id',
        'username': 'friend',
        'nickname': 'Friend'
      },
    });
    await tester.pumpWidget(CupertinoApp(home: WeChatMomentTile(item: item)));
    expect(tester.widget<UserAvatar>(find.byType(UserAvatar)).fallbackSeed,
        'friend');
  });
}
