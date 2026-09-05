import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_home_page.dart';

/// BUG1（被邀端，关闭自动入群）：待处理群邀请 tile——接受/拒绝可操作。
void main() {
  testWidgets('待处理邀请 tile：群名 + 邀请文案 + 接受/拒绝按钮', (tester) async {
    var accepted = 0;
    var declined = 0;
    await tester.pumpWidget(CupertinoApp(
      home: Center(
        child: SizedBox(
          width: 400,
          child: PendingGroupInviteTile(
            roomId: '!g1:x',
            roomName: '项目讨论组',
            onAccept: () => accepted++,
            onDecline: () => declined++,
          ),
        ),
      ),
    ));

    expect(find.text('项目讨论组'), findsOneWidget);
    expect(find.text('邀请你加入群聊'), findsOneWidget);
    expect(find.byKey(const ValueKey('accept-invite-!g1:x')), findsOneWidget);
    expect(find.byKey(const ValueKey('decline-invite-!g1:x')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('accept-invite-!g1:x')));
    expect(accepted, 1);
    await tester.tap(find.byKey(const ValueKey('decline-invite-!g1:x')));
    expect(declined, 1);
  });

  testWidgets('空群名回退为通用文案', (tester) async {
    await tester.pumpWidget(const CupertinoApp(
      home: Center(
        child: SizedBox(
          width: 400,
          child: PendingGroupInviteTile(
            roomId: '!g2:x',
            roomName: '',
            onAccept: null,
            onDecline: null,
          ),
        ),
      ),
    ));
    expect(find.text('群聊邀请'), findsOneWidget);
  });
}
