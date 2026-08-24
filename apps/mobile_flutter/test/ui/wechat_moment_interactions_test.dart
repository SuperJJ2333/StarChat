import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/moments/moment_models.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';
import 'package:liuhetong_mobile/ui/moments/wechat_moment_tile.dart';

void main() {
  test(
      'moment author preserves identity sources and authoritative display name',
      () {
    final author = MomentAuthor.fromJson({
      'user_id': 'u1',
      'username': 'alice_id',
      'nickname': 'Alice',
      'remark': '项目小爱',
      'display_name': '项目小爱',
      'avatar_url':
          'https://media.example.test/avatars/u1/avatar.png?sig=secret',
    });

    expect(author.username, 'alice_id');
    expect(author.nickname, 'Alice');
    expect(author.remark, '项目小爱');
    expect(author.displayName, '项目小爱');
  });

  testWidgets(
      'moment tile renders display name and diagnoses avatar as feed source',
      (tester) async {
    final item = MomentItem.fromJson({
      'id': 'm1',
      'author': {
        'user_id': 'u1',
        'username': 'alice_id',
        'nickname': 'Alice',
        'remark': '项目小爱',
        'display_name': '项目小爱',
        'avatar_url': null,
      },
      'text': '朋友圈正文',
      'image_urls': <String>[],
      'created_at': DateTime.now().toIso8601String(),
      'viewer_has_liked': false,
      'like_count': 0,
      'like_users': <Map<String, dynamic>>[],
      'comments': <Map<String, dynamic>>[],
    });

    await tester.pumpWidget(
      CupertinoApp(home: WeChatMomentTile(item: item)),
    );

    expect(find.text('项目小爱'), findsOneWidget);
    expect(find.text('Alice'), findsNothing);
    final avatar = tester.widget<UserAvatar>(find.byType(UserAvatar));
    expect(avatar.nickname, '项目小爱');
    expect(avatar.diagnosticSource, 'moments-feed');
  });
}
