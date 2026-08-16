import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/auth/login_page.dart';
import 'package:liuhetong_mobile/features/auth/registration_controller.dart';
import 'package:liuhetong_mobile/features/auth/registration_page.dart';
import 'package:liuhetong_mobile/features/auth/verification_page.dart';
import 'package:liuhetong_mobile/ui/components/auth_surface_card.dart';
import 'package:liuhetong_mobile/ui/components/modern_action_button.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';

final class PageGateway implements RegistrationGateway {
  @override
  Future<bool> validateInvitation(String invitationCode) async => true;
  @override
  Future<RegistrationReceipt> register({
    required String username,
    required String email,
    required String password,
    required String invitationCode,
  }) async =>
      const RegistrationReceipt(
        registrationSession: 'session',
        status: 'PENDING_EMAIL',
        resendAfterSeconds: 60,
      );
  @override
  Future<int> resendVerification(String registrationSession) async => 60;
  @override
  Future<RegistrationStatusReceipt> registrationStatus(
    String registrationSession,
  ) async =>
      const RegistrationStatusReceipt(status: 'ACTIVE', resendAfterSeconds: 0);
  @override
  Future<void> verifyEmail({
    required String registrationSession,
    String? code,
    String? token,
  }) async {}
}

void useIPhone15Viewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(393, 852);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

void main() {
  testWidgets(
    'login registration and verification share the immersive background',
    (tester) async {
      final api = BusinessApiClient(
        baseUri: Uri.parse('http://localhost'),
        sessionStore: SecureSessionStore(),
      );
      final controller = RegistrationController(gateway: PageGateway());
      final pages = <Widget>[
        LoginPage(api: api, onLogin: (_, __) async {}),
        RegistrationPage(
          controller: controller,
          onVerification: (_) {},
          onBack: () {},
        ),
        VerificationPage(
          controller: controller,
          onChangeEmail: () {},
          onCompleted: () {},
        ),
      ];
      for (final page in pages) {
        await tester.pumpWidget(CupertinoApp(home: page));
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Image &&
                widget.image is AssetImage &&
                (widget.image as AssetImage).assetName == 'assets/landing.png',
          ),
          findsOneWidget,
        );
        expect(find.byType(SvgPicture), findsOneWidget);
        expect(find.byKey(const Key('auth-brand-logo')), findsOneWidget);
      }
    },
  );
  testWidgets('login follows the 10 Auth default frame structure', (
    tester,
  ) async {
    final api = BusinessApiClient(
      baseUri: Uri.parse('http://localhost'),
      sessionStore: SecureSessionStore(),
    );
    await tester.pumpWidget(
      CupertinoApp(
        home: LoginPage(api: api, onLogin: (_, __) async {}, onRegister: () {}),
      ),
    );
    expect(find.byKey(const Key('auth-login-form')), findsOneWidget);
    expect(find.byKey(const Key('auth-surface-card')), findsOneWidget);
    expect(find.text('畅聊'), findsOneWidget);
    expect(find.text('使用用户名或邮箱登录'), findsOneWidget);
    expect(find.text('用户名/邮箱'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(find.text('我已同意'), findsOneWidget);
    expect(find.text('《用户协议》'), findsOneWidget);
    expect(find.text('《隐私政策》'), findsOneWidget);
    expect(find.text('还没有账号？'), findsOneWidget);
    expect(find.text('立刻注册'), findsOneWidget);
    expect(find.text('注册账号'), findsNothing);
  });
  testWidgets('new landing keeps the login card in the first viewport', (
    tester,
  ) async {
    useIPhone15Viewport(tester);
    final api = BusinessApiClient(
      baseUri: Uri.parse('http://localhost'),
      sessionStore: SecureSessionStore(),
    );
    await tester.pumpWidget(
      CupertinoApp(home: LoginPage(api: api, onLogin: (_, __) async {})),
    );
    await tester.pumpAndSettle();

    final top =
        tester.getTopLeft(find.byKey(const Key('auth-surface-card'))).dy;
    expect(top, greaterThanOrEqualTo(96));
    expect(top, lessThanOrEqualTo(160));
  });
  testWidgets('login requires agreement before submitting', (tester) async {
    useIPhone15Viewport(tester);
    final api = BusinessApiClient(
      baseUri: Uri.parse('http://localhost'),
      sessionStore: SecureSessionStore(),
    );
    var submissions = 0;
    await tester.pumpWidget(
      CupertinoApp(
        home: LoginPage(
          api: api,
          onLogin: (_, __) async => submissions += 1,
          onAuthenticated: () async {},
        ),
      ),
    );

    ModernActionButton loginButton() => tester.widget<ModernActionButton>(
          find.widgetWithText(ModernActionButton, '登录'),
        );

    expect(find.byKey(const Key('auth-agreement-checkbox')), findsOneWidget);
    expect(loginButton().onPressed, isNull);

    await tester.enterText(
      find.byKey(const Key('auth-login-identity')),
      'alice',
    );
    await tester.enterText(
      find.byKey(const Key('auth-login-password')),
      'correct horse battery staple',
    );
    final agreement = find.byKey(const Key('auth-agreement-checkbox'));
    await tester.ensureVisible(agreement);
    await tester.tap(agreement);
    await tester.pump();

    expect(loginButton().onPressed, isNotNull);
    final login = find.widgetWithText(ModernActionButton, '登录');
    await tester.ensureVisible(login);
    await tester.tap(login);
    await tester.pumpAndSettle();
    expect(submissions, 1);
  });
  testWidgets('agreement policies and inline registration expose callbacks', (
    tester,
  ) async {
    useIPhone15Viewport(tester);
    final api = BusinessApiClient(
      baseUri: Uri.parse('http://localhost'),
      sessionStore: SecureSessionStore(),
    );
    var userAgreementOpens = 0;
    var privacyPolicyOpens = 0;
    var registrations = 0;
    await tester.pumpWidget(
      CupertinoApp(
        home: LoginPage(
          api: api,
          onLogin: (_, __) async {},
          onUserAgreement: () => userAgreementOpens += 1,
          onPrivacyPolicy: () => privacyPolicyOpens += 1,
          onRegister: () => registrations += 1,
        ),
      ),
    );

    for (final key in const [
      Key('auth-user-agreement-link'),
      Key('auth-privacy-policy-link'),
      Key('auth-register-link'),
    ]) {
      final action = find.byKey(key);
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pump();
    }
    expect(userAgreementOpens, 1);
    expect(privacyPolicyOpens, 1);
    expect(registrations, 1);
  });
  testWidgets('login loading freezes agreement and registration actions', (
    tester,
  ) async {
    useIPhone15Viewport(tester);
    final api = BusinessApiClient(
      baseUri: Uri.parse('http://localhost'),
      sessionStore: SecureSessionStore(),
    );
    final pending = Completer<void>();
    var registrations = 0;
    await tester.pumpWidget(
      CupertinoApp(
        home: LoginPage(
          api: api,
          onLogin: (_, __) => pending.future,
          onAuthenticated: () async {},
          onRegister: () => registrations += 1,
        ),
      ),
    );
    await tester.enterText(find.byType(CupertinoTextField).at(0), 'alice');
    await tester.enterText(find.byType(CupertinoTextField).at(1), 'secret');
    final agreement = find.byKey(const Key('auth-agreement-checkbox'));
    await tester.ensureVisible(agreement);
    await tester.tap(agreement);
    await tester.pump();
    final login = find.widgetWithText(ModernActionButton, '登录');
    await tester.ensureVisible(login);
    await tester.tap(login);
    await tester.pump();

    expect(
      tester.widget<CupertinoButton>(agreement).onPressed,
      isNull,
    );
    expect(
      tester.widget<ModernActionButton>(login).loading,
      isTrue,
    );
    final register = find.byKey(const Key('auth-register-link'));
    await tester.ensureVisible(register);
    await tester.tap(register);
    expect(registrations, 0);

    pending.complete();
    await tester.pumpAndSettle();
  });
  testWidgets('agreement copy stays in one 44px row at card width', (
    tester,
  ) async {
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 297,
              child: AuthAgreementRow(
                value: false,
                enabled: true,
                onChanged: (_) {},
                onUserAgreement: () {},
                onPrivacyPolicy: () {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byType(AuthAgreementRow)).height,
      WeChatDimensions.minimumTouchTarget,
    );
  });
  testWidgets('dark login title uses the dark primary text token', (
    tester,
  ) async {
    useIPhone15Viewport(tester);
    final api = BusinessApiClient(
      baseUri: Uri.parse('http://localhost'),
      sessionStore: SecureSessionStore(),
    );
    await tester.pumpWidget(
      CupertinoApp(
        theme: const CupertinoThemeData(brightness: Brightness.dark),
        home: LoginPage(api: api, onLogin: (_, __) async {}),
      ),
    );
    final title = tester.widget<Text>(find.text('畅聊'));
    expect(title.style?.color, WeChatColors.darkTextPrimary);
  });
  testWidgets('unchecked agreement gives login a muted disabled treatment', (
    tester,
  ) async {
    final api = BusinessApiClient(
      baseUri: Uri.parse('http://localhost'),
      sessionStore: SecureSessionStore(),
    );
    await tester.pumpWidget(
      CupertinoApp(home: LoginPage(api: api, onLogin: (_, __) async {})),
    );
    final button = find.widgetWithText(ModernActionButton, '登录');
    final icon = tester.widget<Icon>(
      find.descendant(of: button, matching: find.byType(Icon)),
    );
    final label = tester.widget<Text>(
      find.descendant(of: button, matching: find.text('登录')),
    );
    expect(icon.color, WeChatColors.textTertiary);
    expect(label.style?.color, WeChatColors.textTertiary);
  });
  testWidgets('registration follows the 10 Auth default frame structure', (
    tester,
  ) async {
    final controller = RegistrationController(gateway: PageGateway());
    await tester.pumpWidget(
      CupertinoApp(
        home: RegistrationPage(
          controller: controller,
          onVerification: (_) {},
          onBack: () {},
        ),
      ),
    );
    expect(find.byKey(const Key('auth-registration-form')), findsOneWidget);
    expect(find.byKey(const Key('auth-surface-card')), findsOneWidget);
    expect(find.text('创建畅聊账号'), findsOneWidget);
    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('邮箱'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('邀请码'), findsOneWidget);
    expect(find.text('创建账号'), findsOneWidget);
    expect(find.byKey(const Key('auth-agreement-checkbox')), findsNothing);
  });
  testWidgets(
    'registration contains all required fields and invitation gates submit',
    (tester) async {
      final controller = RegistrationController(gateway: PageGateway());
      await tester.pumpWidget(
        CupertinoApp(
          home: RegistrationPage(
            controller: controller,
            onVerification: (_) {},
            onBack: () {},
          ),
        ),
      );
      expect(find.byType(CupertinoTextField), findsNWidgets(4));
      expect(find.text('邀请码（必填）'), findsOneWidget);
      expect(
        tester
            .widget<ModernActionButton>(
              find.widgetWithText(ModernActionButton, '创建账号'),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byType(CupertinoTextField).last, 'INVITE');
      await tester.pump();
      expect(
        tester
            .widget<ModernActionButton>(
              find.widgetWithText(ModernActionButton, '创建账号'),
            )
            .onPressed,
        isNotNull,
      );
    },
  );
  testWidgets(
    'verification exposes code link result resend change email and status',
    (tester) async {
      final controller = RegistrationController(gateway: PageGateway());
      await controller.register(
        username: 'alice',
        email: 'a@x.test',
        password: 'long-password',
        invitationCode: 'INVITE',
      );
      await tester.pumpWidget(
        CupertinoApp(
          home: VerificationPage(
            controller: controller,
            onChangeEmail: () {},
            onCompleted: () {},
          ),
        ),
      );
      expect(find.textContaining('验证链接结果'), findsOneWidget);
      expect(find.textContaining('秒后重发'), findsOneWidget);
      expect(find.text('修改邮箱'), findsOneWidget);
      expect(find.byKey(const Key('registration-status')), findsOneWidget);
    },
  );
  testWidgets('keyboard inset moves form but not landing background', (
    tester,
  ) async {
    final api = BusinessApiClient(
      baseUri: Uri.parse('http://localhost'),
      sessionStore: SecureSessionStore(),
    );
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(viewInsets: EdgeInsets.zero),
        child: CupertinoApp(
          home: LoginPage(api: api, onLogin: (_, __) async {}),
        ),
      ),
    );
    final before = tester.getTopLeft(find.byType(Image).first);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(viewInsets: EdgeInsets.only(bottom: 300)),
        child: CupertinoApp(
          home: LoginPage(api: api, onLogin: (_, __) async {}),
        ),
      ),
    );
    expect(tester.getTopLeft(find.byType(Image).first), before);
  });
}
