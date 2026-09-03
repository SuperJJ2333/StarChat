import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/profile/invite_code_page.dart';
import 'package:liuhetong_mobile/features/profile/invite_controller.dart';

/// 统一邀请码（规格 §6.2）：固定个人注册邀请码，不轮换。
final class FakePersonalInvitationGateway implements PersonalInvitationGateway {
  int fetchCalls = 0;
  Object? fetchError;

  @override
  Future<PersonalInvitation> fetchPersonalInvitation() async {
    fetchCalls++;
    final error = fetchError;
    if (error != null) throw error;
    return const PersonalInvitation(
      code: 'AB2CD3FG',
      maxUses: 20,
      useCount: 3,
      shareUrl: 'https://invite.example.test/register?code=AB2CD3FG',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 捕获 Clipboard.setData 写入的文本，供 Clipboard.getData 读取。
  String? clipboardText;
  testerBinding() => TestDefaultBinaryMessengerBinding.instance;
  setUp(() {
    clipboardText = null;
    testerBinding().defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            clipboardText = (call.arguments as Map)['text'] as String?;
            return null;
          case 'Clipboard.getData':
            return <String, dynamic>{'text': clipboardText};
          default:
            return null;
        }
      },
    );
  });
  tearDown(() {
    testerBinding()
        .defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('load fetches stable personal invitation', () async {
    final controller =
        InviteCodeController(gateway: FakePersonalInvitationGateway());
    await controller.load();

    expect(controller.state.status, InviteCodeStatus.ready);
    expect(controller.state.invite!.code, 'AB2CD3FG');
    expect(controller.state.invite!.remainingUses, 17);
    controller.dispose();
  });

  test('load failure lands in failed state and retry recovers', () async {
    final gateway = FakePersonalInvitationGateway()
      ..fetchError = Exception('offline');
    final controller = InviteCodeController(gateway: gateway);
    await controller.load();

    expect(controller.state.status, InviteCodeStatus.failed);
    expect(controller.state.message, contains('失败'));

    gateway.fetchError = null;
    await controller.load();
    expect(controller.state.status, InviteCodeStatus.ready);
    expect(gateway.fetchCalls, 2);
    controller.dispose();
  });

  testWidgets('invite page renders code and remaining uses', (tester) async {
    final controller =
        InviteCodeController(gateway: FakePersonalInvitationGateway());
    await tester.pumpWidget(
      CupertinoApp(home: InviteCodePage(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('invite-code-value')), findsOneWidget);
    expect(find.text('AB2CD3FG'), findsOneWidget);
    expect(find.byKey(const Key('invite-remaining-uses')), findsOneWidget);
    expect(find.text('可邀请 17 位好友'), findsOneWidget);
    expect(find.text('我的邀请码'), findsOneWidget);
    // 统一邀请码：不再有 30 分钟轮换倒计时。
    expect(find.byKey(const Key('invite-countdown')), findsNothing);
    controller.dispose();
  });

  testWidgets('copy code action writes clipboard with a toast', (tester) async {
    final controller =
        InviteCodeController(gateway: FakePersonalInvitationGateway());
    await tester.pumpWidget(
      CupertinoApp(home: InviteCodePage(controller: controller)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('invite-copy-code')));
    await tester.pump();
    expect(clipboardText, 'AB2CD3FG');
    expect(find.byKey(const Key('invite-toast')), findsOneWidget);

    await tester.tap(find.byKey(const Key('invite-copy-link')));
    await tester.pump();
    expect(clipboardText, 'https://invite.example.test/register?code=AB2CD3FG');
    controller.dispose();
  });
}
