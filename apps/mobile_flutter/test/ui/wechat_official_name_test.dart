import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/support_identity_repository.dart';
import 'package:liuhetong_mobile/ui/components/wechat_official_name.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';

void main() {
  testWidgets('renders a verified badge as independent yellow caption text',
      (tester) async {
    final repository = SupportIdentityRepository(_Gateway());
    await repository.warm(['support-1']);

    await tester.pumpWidget(CupertinoApp(
      home: WeChatOfficialName(
        name: '非常长的联系人备注名称用于截断测试',
        supportIdentities: repository,
        userId: 'support-1',
      ),
    ));

    expect(find.text('非常长的联系人备注名称用于截断测试'), findsOneWidget);
    final badge = tester.widget<Text>(find.text('@官方客服'));
    expect(badge.style?.color, WeChatColors.supportIdentityYellow);
    expect(badge.style?.fontSize, WeChatTypography.caption);
  });

  testWidgets('does not turn a Matrix-looking name into a badge', (tester) async {
    await tester.pumpWidget(const CupertinoApp(
      home: WeChatOfficialName(name: '普通用户 @官方客服'),
    ));

    expect(find.text('@官方客服'), findsNothing);
    expect(find.text('普通用户 @官方客服'), findsOneWidget);
  });
}

final class _Gateway implements SupportIdentityGateway {
  @override
  Future<List<SupportIdentity>> lookupSupportIdentities(
          List<String> userIds) async =>
      const [
        SupportIdentity(
          queryId: 'support-1',
          userId: 'support-1',
          matrixUserId: '@support:example.test',
          badge: '官方客服',
          role: SupportRole.supportAgent,
        ),
      ];
}
