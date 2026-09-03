import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/auth/login_page.dart';
import 'package:liuhetong_mobile/features/auth/registration_controller.dart';
import 'package:liuhetong_mobile/features/auth/invitation_validation.dart';
import 'package:liuhetong_mobile/features/auth/registration_page.dart';
import 'package:liuhetong_mobile/features/auth/verification_page.dart';
import 'package:liuhetong_mobile/ui/components/auth_surface_card.dart';
import 'package:liuhetong_mobile/ui/components/modern_action_button.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';

final class PageGateway implements RegistrationGateway {
  Object? registerError;
  Object? verifyError;
  @override
  Future<InvitationValidationResult> validateInvitation(
          String invitationCode) async =>
      const InvitationValidationResult(
          InvitationValidationState.ready, '邀请码可用');
  @override
  Future<RegistrationReceipt> register({
    required String username,
    String? nickname,
    required String email,
    required String password,
    required String invitationCode,
  }) async =>
      registerError != null
          ? throw registerError!
          : const RegistrationReceipt(
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
  }) async {
    if (verifyError != null) throw verifyError!;
  }
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
  testWidgets('login password visibility toggles the secure field',
      (tester) async {
    final api = BusinessApiClient(
      baseUri: Uri.parse('http://localhost'),
      sessionStore: SecureSessionStore(),
    );
    await tester.pumpWidget(
        CupertinoApp(home: LoginPage(api: api, onLogin: (_, __) async {})));
    final password = tester.widget<CupertinoTextField>(find.descendant(
      of: find.byKey(const Key('auth-login-password')),
      matching: find.byType(CupertinoTextField),
    ));
    expect(password.obscureText, isTrue);
    await tester.tap(find.byKey(const Key('auth-login-password-visibility')));
    await tester.pump();
    expect(
        tester
            .widget<CupertinoTextField>(find.descendant(
              of: find.byKey(const Key('auth-login-password')),
              matching: find.byType(CupertinoTextField),
            ))
            .obscureText,
        isFalse);
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
    expect(find.text('发送验证邮件'), findsOneWidget);
    expect(find.byKey(const Key('auth-registration-send-email-action')),
        findsNothing);
    expect(find.byKey(const Key('auth-agreement-checkbox')), findsNothing);
  });
  testWidgets(
      'registration keeps email sending as the single highlighted action',
      (tester) async {
    final controller = RegistrationController(gateway: PageGateway());
    await tester.pumpWidget(CupertinoApp(
      home: RegistrationPage(
        controller: controller,
        onVerification: (_) {},
        onBack: () {},
      ),
    ));

    final send = find.byKey(const Key('auth-registration-send-code'));
    expect(send, findsOneWidget);
    expect(find.byKey(const Key('auth-registration-send-email-action')),
        findsNothing);
    final background = tester.widget<Container>(
      find.descendant(of: send, matching: find.byType(Container)).first,
    );
    expect((background.decoration as BoxDecoration).color,
        WeChatColors.brandPrimary);
  });
  testWidgets('registration preserves entered draft after returning to login',
      (tester) async {
    final controller = RegistrationController(gateway: PageGateway());
    late StateSetter setPage;
    var registerVisible = true;
    await tester.pumpWidget(CupertinoApp(
      home: StatefulBuilder(builder: (context, setState) {
        setPage = setState;
        return registerVisible
            ? RegistrationPage(
                controller: controller,
                onVerification: (_) {},
                onBack: () => setPage(() => registerVisible = false),
              )
            : CupertinoButton(
                child: const Text('再次注册'),
                onPressed: () => setPage(() => registerVisible = true),
              );
      }),
    ));
    final fields = find.byType(CupertinoTextField);
    await tester.enterText(fields.at(0), '昵称');
    await tester.enterText(fields.at(1), 'chat-id');
    await tester.enterText(fields.at(2), 'correct horse battery staple');
    await tester.enterText(fields.at(3), 'correct horse battery staple');
    await tester.enterText(fields.at(4), 'INVITE');
    await tester.enterText(fields.at(5), 'draft@example.test');
    final back = find.widgetWithText(ModernActionButton, '返回登录');
    tester.widget<ModernActionButton>(back).onPressed!();
    await tester.pump();
    await tester.tap(find.text('再次注册'));
    await tester.pump();

    final restored = find.byType(CupertinoTextField);
    expect(tester.widget<CupertinoTextField>(restored.at(0)).controller?.text,
        '昵称');
    expect(tester.widget<CupertinoTextField>(restored.at(5)).controller?.text,
        'draft@example.test');
  });
  testWidgets('taken email appears once below the email field', (tester) async {
    final gateway = PageGateway()
      ..registerError = const BusinessApiException(
          statusCode: 409, code: 'EMAIL_TAKEN', message: '邮箱已被使用');
    final controller = RegistrationController(gateway: gateway);
    await tester.pumpWidget(CupertinoApp(
      home: RegistrationPage(
        controller: controller,
        onVerification: (_) {},
        onBack: () {},
      ),
    ));
    final fields = find.byType(CupertinoTextField);
    await tester.enterText(fields.at(0), '昵称');
    await tester.enterText(fields.at(1), 'chat-id');
    await tester.enterText(fields.at(2), 'correct horse battery staple');
    await tester.enterText(fields.at(3), 'correct horse battery staple');
    await tester.enterText(fields.at(4), 'INVITE');
    await tester.enterText(fields.at(5), 'taken@example.test');
    tester
        .widget<CupertinoButton>(
          find.byKey(const Key('auth-registration-send-code')),
        )
        .onPressed!();
    await tester.pump();

    expect(find.text('邮箱已被使用'), findsOneWidget);
    expect(
        find.byKey(const Key('auth-registration-error-email')), findsOneWidget);
    expect(find.byKey(const Key('auth-registration-error')), findsNothing);
  });
  testWidgets(
    'registration contains all required fields and validates before sending',
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
      // 统一邀请码：注册页只有一个邀请码字段（原好友邀请码已并入）。
      expect(find.byType(CupertinoTextField), findsNWidgets(6));
      expect(find.text('畅聊号'), findsOneWidget);
      expect(find.text('再次输入密码'), findsNWidgets(2));
      expect(find.byKey(const Key('auth-registration-password-visibility')),
          findsOneWidget);
      expect(
          find.byKey(
              const Key('auth-registration-password-confirm-visibility')),
          findsOneWidget);
      expect(
          find.byKey(const Key('auth-registration-send-code')), findsOneWidget);
      expect(find.text('邀请码（必填）'), findsOneWidget);
      expect(
        tester
            .widget<CupertinoButton>(
              find.byKey(const Key('auth-registration-send-code')),
            )
            .onPressed,
        isNotNull,
      );
      final fields = find.byType(CupertinoTextField);
      await tester.enterText(fields.at(0), 'Alice');
      await tester.enterText(fields.at(1), 'alice');
      await tester.enterText(fields.at(2), 'correct horse battery staple');
      await tester.enterText(fields.at(3), 'correct horse battery staple');
      await tester.enterText(fields.at(4), 'INVITE');
      await tester.enterText(fields.at(5), 'alice@example.test');
      await tester.pump();
      expect(
        tester
            .widget<CupertinoButton>(
              find.byKey(const Key('auth-registration-send-code')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );
  testWidgets(
      'registration puts each invalid field error below that field without sending',
      (tester) async {
    final controller = RegistrationController(gateway: PageGateway());
    await tester.pumpWidget(CupertinoApp(
      home: RegistrationPage(
        controller: controller,
        onVerification: (_) {},
        onBack: () {},
      ),
    ));

    final send = find.byKey(const Key('auth-registration-send-code'));
    tester.widget<CupertinoButton>(send).onPressed!();
    await tester.pump();

    for (final field in const [
      'nickname',
      'username',
      'password',
      'invitation_code',
      'email',
    ]) {
      expect(find.byKey(Key('auth-registration-error-$field')), findsOneWidget);
    }
    expect(controller.state.registrationSession, isNull);
  });
  testWidgets('registration shows mismatch feedback and gates submit',
      (tester) async {
    final controller = RegistrationController(gateway: PageGateway());
    await tester.pumpWidget(CupertinoApp(
      home: RegistrationPage(
        controller: controller,
        onVerification: (_) {},
        onBack: () {},
      ),
    ));
    final fields = find.byType(CupertinoTextField);
    await tester.enterText(fields.at(0), 'Alice');
    await tester.enterText(fields.at(1), 'alice');
    await tester.enterText(fields.at(2), 'correct horse battery staple');
    await tester.enterText(fields.at(3), 'different password');
    await tester.enterText(fields.at(4), 'INVITE');
    await tester.enterText(fields.at(5), 'alice@example.test');
    await tester.pump();
    expect(find.text('两次密码输入不一致'), findsOneWidget);
    expect(
      tester
          .widget<CupertinoButton>(
            find.byKey(const Key('auth-registration-send-code')),
          )
          .onPressed,
      isNotNull,
    );
  });
  testWidgets(
      'registration starts a sixty second resend cooldown after sending',
      (tester) async {
    final controller = RegistrationController(gateway: PageGateway());
    await tester.pumpWidget(CupertinoApp(
      home: RegistrationPage(
        controller: controller,
        onVerification: (_) {},
        onBack: () {},
      ),
    ));
    final fields = find.byType(CupertinoTextField);
    await tester.enterText(fields.at(0), 'Alice');
    await tester.enterText(fields.at(1), 'alice');
    await tester.enterText(fields.at(2), 'correct horse battery staple');
    await tester.enterText(fields.at(3), 'correct horse battery staple');
    await tester.enterText(fields.at(4), 'INVITE');
    await tester.enterText(fields.at(5), 'alice@example.test');
    await tester.pump();

    final action = find.byKey(const Key('auth-registration-send-code'));
    tester.widget<CupertinoButton>(action).onPressed!();
    await tester.pump();
    expect(controller.state.resendAfterSeconds, 60);
    expect(find.text('60s'), findsOneWidget);
    expect(tester.widget<CupertinoButton>(action).onPressed, isNull);
    controller.dispose();
  });
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
      expect(find.text('等待邮箱验证'), findsNothing);
      expect(find.byKey(const Key('auth-verification-verify')), findsOneWidget);
      expect(find.byKey(const Key('auth-verification-resend')), findsOneWidget);
      expect(find.byKey(const Key('auth-verification-change-email')),
          findsOneWidget);
      controller.dispose();
    },
  );
  testWidgets('verification shows code error above field and clears on edit',
      (tester) async {
    final controller = RegistrationController(
      gateway: PageGateway()
        ..verifyError = const BusinessApiException(
          statusCode: 422,
          code: 'EMAIL_VERIFICATION_CODE_INVALID',
          message: '验证码无效',
        ),
    );
    await controller.register(
      username: 'alice',
      email: 'alice@example.test',
      password: 'correct horse battery staple',
      invitationCode: 'INVITE',
    );
    await tester.pumpWidget(CupertinoApp(
      home: VerificationPage(
        controller: controller,
        onChangeEmail: () {},
        onCompleted: () {},
      ),
    ));

    await tester.enterText(find.byType(CupertinoTextField), '000000');
    await tester.tap(find.byKey(const Key('auth-verification-verify')));
    await tester.pump();

    final error = find.byKey(const Key('auth-verification-code-error'));
    expect(error, findsOneWidget);
    expect(find.text('验证码错误，请重新输入'), findsOneWidget);
    final errorText = tester.widget<Text>(
      find.descendant(of: error, matching: find.text('验证码错误，请重新输入')),
    );
    expect(
      find.descendant(of: error, matching: find.byType(Container)),
      findsOneWidget,
    );
    expect(errorText.style?.fontSize, greaterThanOrEqualTo(14));

    await tester.enterText(find.byType(CupertinoTextField), '123456');
    await tester.pump();
    expect(error, findsNothing);
    expect(find.byKey(const Key('auth-verification-verify')), findsOneWidget);
    controller.dispose();
  });
  testWidgets('verification button provides a nonblocking press scale',
      (tester) async {
    var presses = 0;
    await tester.pumpWidget(CupertinoApp(
      home: SizedBox(
        width: 240,
        child: ModernActionButton(
          key: const Key('auth-verification-verify'),
          icon: CupertinoIcons.check_mark_circled,
          label: '验证并继续',
          onPressed: () => presses++,
        ),
      ),
    ));
    final button = find.byKey(const Key('auth-verification-verify'));
    final animation =
        find.descendant(of: button, matching: find.byType(AnimatedScale));
    expect(tester.widget<AnimatedScale>(animation).duration,
        const Duration(milliseconds: 150));

    final gesture = await tester.startGesture(tester.getCenter(button));
    await tester.pump(const Duration(milliseconds: 75));
    final activeScale = tester.widget<AnimatedScale>(animation);
    expect(activeScale.scale, .98);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.widget<AnimatedScale>(animation).scale, 1);
    expect(presses, 1);
  });
  testWidgets('registration saves the complete draft before verification',
      (tester) async {
    final controller = RegistrationController(gateway: PageGateway());
    await tester.pumpWidget(CupertinoApp(
      home: RegistrationPage(
        controller: controller,
        onVerification: (_) {},
        onBack: () {},
      ),
    ));
    final fields = find.byType(CupertinoTextField);
    await tester.enterText(fields.at(0), '昵称');
    await tester.enterText(fields.at(1), 'chat-id');
    await tester.enterText(fields.at(2), 'correct horse battery staple');
    await tester.enterText(fields.at(3), 'correct horse battery staple');
    await tester.enterText(fields.at(4), 'INVITE');
    await tester.enterText(fields.at(5), 'draft@example.test');
    tester
        .widget<CupertinoButton>(
          find.byKey(const Key('auth-registration-send-code')),
        )
        .onPressed!();
    await tester.pump();

    expect(controller.draft.email, 'draft@example.test');
    expect(controller.draft.password, 'correct horse battery staple');
    controller.dispose();
  });
  testWidgets('verification countdown continues after changing email',
      (tester) async {
    final controller = RegistrationController(gateway: PageGateway());
    await tester.pumpWidget(CupertinoApp(
      home: RegistrationPage(
        controller: controller,
        onVerification: (_) {},
        onBack: () {},
      ),
    ));
    final fields = find.byType(CupertinoTextField);
    await tester.enterText(fields.at(0), '昵称');
    await tester.enterText(fields.at(1), 'chat-id');
    await tester.enterText(fields.at(2), 'correct horse battery staple');
    await tester.enterText(fields.at(3), 'correct horse battery staple');
    await tester.enterText(fields.at(4), 'INVITE');
    await tester.enterText(fields.at(5), 'countdown@example.test');
    tester
        .widget<CupertinoButton>(
          find.byKey(const Key('auth-registration-send-code')),
        )
        .onPressed!();
    await tester.pump();
    await tester.pumpWidget(CupertinoApp(
      home: VerificationPage(
        controller: controller,
        onChangeEmail: () {},
        onCompleted: () {},
      ),
    ));
    await tester.pump(const Duration(seconds: 1));

    expect(controller.state.resendAfterSeconds, 59);
    controller.dispose();
  });
  testWidgets('registration verification code carries into verification step',
      (tester) async {
    final controller = RegistrationController(gateway: PageGateway());
    controller.setVerificationCodeHint('123456');
    await tester.pumpWidget(CupertinoApp(
      home: VerificationPage(
        controller: controller,
        onChangeEmail: () {},
        onCompleted: () {},
      ),
    ));
    expect(
      tester
          .widget<CupertinoTextField>(find.byType(CupertinoTextField))
          .controller
          ?.text,
      '123456',
    );
  });
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

  testWidgets('login rejects malformed email addresses with a clear error',
      (tester) async {
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

    await tester.enterText(find.byKey(const Key('auth-login-identity')), 'a@b');
    await tester.enterText(
      find.byKey(const Key('auth-login-password')),
      'correct horse battery staple',
    );
    final agreement = find.byKey(const Key('auth-agreement-checkbox'));
    await tester.ensureVisible(agreement);
    await tester.tap(agreement);
    await tester.pump();
    final login = find.widgetWithText(ModernActionButton, '登录');
    await tester.ensureVisible(login);
    await tester.tap(login);
    await tester.pumpAndSettle();

    expect(find.text('请输入正确的邮箱地址'), findsOneWidget);
    expect(submissions, 0);
  });

  testWidgets('login accepts well formed email identifiers', (tester) async {
    useIPhone15Viewport(tester);
    final api = BusinessApiClient(
      baseUri: Uri.parse('http://localhost'),
      sessionStore: SecureSessionStore(),
    );
    var submittedIdentity = '';
    await tester.pumpWidget(
      CupertinoApp(
        home: LoginPage(
          api: api,
          onLogin: (identity, _) async => submittedIdentity = identity,
          onAuthenticated: () async {},
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('auth-login-identity')),
      'Alice@Example.com',
    );
    await tester.enterText(
      find.byKey(const Key('auth-login-password')),
      'correct horse battery staple',
    );
    final agreement = find.byKey(const Key('auth-agreement-checkbox'));
    await tester.ensureVisible(agreement);
    await tester.tap(agreement);
    await tester.pump();
    final login = find.widgetWithText(ModernActionButton, '登录');
    await tester.ensureVisible(login);
    await tester.tap(login);
    await tester.pumpAndSettle();

    expect(find.text('请输入正确的邮箱地址'), findsNothing);
    expect(submittedIdentity, 'Alice@Example.com');
  });
}
