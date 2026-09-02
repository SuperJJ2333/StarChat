import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/profile/invite_code_page.dart';
import 'package:liuhetong_mobile/features/profile/invite_controller.dart';

final class FakeReferralGateway implements ReferralInviteGateway {
  int fetchCalls = 0;
  Object? fetchError;

  @override
  Future<ReferralInvite> fetchReferralInvite() async {
    fetchCalls++;
    final error = fetchError;
    if (error != null) throw error;
    return ReferralInvite(
      code: 'AB2CD3FG',
      rotatesAt: DateTime.now().toUtc().add(const Duration(minutes: 30)),
      rotatesInSeconds: 1800,
      shareUrl: 'https://invite.example.test/register?code=AB2CD3FG',
      rewardEnabled: false,
    );
  }

  @override
  Future<bool> validateReferralCode(String referralCode) async => true;
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

  test('load fetches invite and exposes countdown', () async {
    final controller = InviteCodeController(gateway: FakeReferralGateway());
    await controller.load();

    expect(controller.state.status, InviteCodeStatus.ready);
    expect(controller.state.invite!.code, 'AB2CD3FG');
    expect(controller.state.remainingSeconds, 1800);
    controller.dispose();
  });

  test('load failure lands in failed state and retry recovers', () async {
    final gateway = FakeReferralGateway()..fetchError = Exception('offline');
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

  testWidgets('invite page renders code and countdown', (tester) async {
    final controller =
        InviteCodeController(gateway: FakeReferralGateway());
    await tester.pumpWidget(
      CupertinoApp(home: InviteCodePage(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('invite-code-value')), findsOneWidget);
    expect(find.text('AB2CD3FG'), findsOneWidget);
    expect(find.byKey(const Key('invite-countdown')), findsOneWidget);
    expect(find.text('我的邀请码'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('copy code action writes clipboard with a toast',
      (tester) async {
    final controller =
        InviteCodeController(gateway: FakeReferralGateway());
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
    expect(clipboardText,
        'https://invite.example.test/register?code=AB2CD3FG');
    controller.dispose();
  });
}
