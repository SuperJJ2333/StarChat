import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/friend_request_review_page.dart';

/// BUG 2：通过朋友验证页——展示 头像/昵称/greeting/remark/tags；
/// 仅点击「通过验证」才触发 accept。
void main() {
  Map request({
    String status = 'PENDING',
    String? remark,
    List tags = const [],
  }) =>
      {
        'id': 'req-1',
        'user_id': 'bob-id',
        'username': 'bob',
        'nickname': 'Bob',
        'avatar_url': null,
        'matrix_user_id': '@bob:test',
        'message': '我是Bob，很高兴认识你',
        'remark': remark,
        'tags': tags,
        'status': status,
        'requested_at': '2026-09-03T00:00:00+00:00',
      };

  Future<void> pumpPage(
    WidgetTester tester, {
    required Map req,
    required void Function() onAccept,
    required void Function() onReject,
  }) async {
    await tester.pumpWidget(
      FriendsReviewHost(
        request: req,
        onAccept: onAccept,
        onReject: onReject,
      ),
    );
  }

  testWidgets('展示打招呼/备注/标签，点击通过验证才触发 accept', (tester) async {
    var accepted = 0;
    var rejected = 0;
    await pumpPage(
      tester,
      req: request(remark: '同事', tags: ['工作', '朋友']),
      onAccept: () => accepted++,
      onReject: () => rejected++,
    );

    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('畅聊号：bob'), findsOneWidget);
    expect(find.text('我是Bob，很高兴认识你'), findsOneWidget);
    expect(find.text('同事'), findsOneWidget);
    expect(find.text('工作'), findsOneWidget);
    expect(find.text('朋友'), findsOneWidget);

    // 初始未触发任何受理动作。
    expect(accepted, 0);
    expect(rejected, 0);

    await tester.tap(find.byKey(const Key('friend-request-accept')));
    await tester.pump();
    expect(accepted, 1, reason: '仅点击通过验证才调用 accept');
    expect(rejected, 0);

    await tester.tap(find.byKey(const Key('friend-request-reject')));
    await tester.pump();
    expect(rejected, 1);
  });

  testWidgets('非待处理状态不显示受理按钮，显示状态文案', (tester) async {
    var accepted = 0;
    await pumpPage(
      tester,
      req: request(status: 'CANCELLED'),
      onAccept: () => accepted++,
      onReject: () {},
    );
    expect(find.byKey(const Key('friend-request-accept')), findsNothing);
    expect(find.byKey(const Key('friend-request-reject')), findsNothing);
    expect(find.text('对方已撤销申请'), findsOneWidget);
    expect(accepted, 0);
  });
}

/// 测试宿主：直接承载 FriendRequestReviewPage。
final class FriendsReviewHost extends StatelessWidget {
  const FriendsReviewHost({
    super.key,
    required this.request,
    required this.onAccept,
    required this.onReject,
  });

  final Map request;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) => CupertinoApp(
        home: FriendRequestReviewPage(
          request: request,
          onAccept: () async => onAccept(),
          onReject: () async => onReject(),
        ),
      );
}
