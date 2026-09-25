import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/business_phone_contracts.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/auth/login_page.dart';
import 'package:liuhetong_mobile/features/auth/login_controller.dart';
import 'package:liuhetong_mobile/ui/components/modern_action_button.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';

void main() {
  testWidgets(
      'valid phone immediately enables green OTP action and explains consent',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var sends = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.invalid'),
        sessionStore: SecureSessionStore(_MemoryStore()),
        client: MockClient((_) async {
          sends++;
          return http.Response('{"status":"accepted"}', 202);
        }));
    await tester.pumpWidget(CupertinoApp(home: LoginPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('手机号登录'));
    await tester.pumpAndSettle();
    final phone = find.byKey(const Key('auth-login-phone'));
    CupertinoButton button() => tester
        .widget<CupertinoButton>(find.widgetWithText(CupertinoButton, '获取验证码'));
    expect(button().onPressed, isNull);
    await tester.enterText(phone, '+86 138 0000 0001');
    await tester.pump();
    expect(button().onPressed, isNotNull);
    expect(tester.widget<Text>(find.text('获取验证码')).style?.color,
        WeChatColors.brandPrimary);
    await tester.tap(find.text('获取验证码'));
    await tester.pump();
    expect(find.text('请先阅读并同意用户协议和隐私政策'), findsOneWidget);
    expect(sends, 0);
    await tester.enterText(phone, '1380000000a');
    await tester.pump();
    expect(button().onPressed, isNull);
    await tester.enterText(phone, '13800000001');
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.byKey(const Key('auth-agreement-checkbox')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('auth-agreement-checkbox')));
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('获取验证码'));
    await tester.tap(find.text('获取验证码'));
    await tester.pump();
    expect(sends, 1);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
  });
  testWidgets(
      'phone host login completes before authentication callback and is never auto retried',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final pending = Completer<void>();
    var calls = 0;
    var authenticated = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.invalid'),
        sessionStore: SecureSessionStore());
    await tester.pumpWidget(CupertinoApp(
        home: LoginPage(
            api: api,
            onPhoneLogin: (phone, code,
                {invitationCode = '',
                termsAccepted = false,
                shouldContinue}) async {
              calls++;
              await pending.future;
            },
            onAuthenticated: () async {
              authenticated++;
            })));
    await tester.pumpAndSettle();
    await tester.tap(find.text('手机号登录'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('auth-login-phone')), '13800000001');
    await tester.enterText(find.byKey(const Key('auth-login-code')), '123456');
    final agreement = find.byKey(const Key('auth-agreement-checkbox'));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(agreement);
    await tester.pumpAndSettle();
    await tester.tap(agreement);
    await tester.pump();
    final login = find.widgetWithText(ModernActionButton, '登录');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(login);
    await tester.tap(login);
    await tester.pump();
    expect(calls, 1);
    expect(authenticated, 0);
    pending.complete();
    await tester.pumpAndSettle();
    expect(authenticated, 1);
    expect(calls, 1);
  });
  testWidgets('phone login is explicit and mounting sends no SMS',
      (tester) async {
    var calls = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.invalid'),
        sessionStore: SecureSessionStore(_MemoryStore()),
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }));
    await tester.pumpWidget(CupertinoApp(home: LoginPage(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('手机号登录'), findsOneWidget);
    await tester.tap(find.text('手机号登录'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('auth-login-phone')), findsOneWidget);
    expect(find.byKey(const Key('auth-login-code')), findsOneWidget);
    expect(calls, 0);
  });
  testWidgets('Matrix stage failure cannot resubmit a consumed phone code',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    SharedPreferences.setMockInitialValues({});
    var phoneLogins = 0;
    var otpRequests = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.invalid'),
        sessionStore: SecureSessionStore(_MemoryStore()),
        client: MockClient((_) async {
          otpRequests++;
          return http.Response('{"status":"accepted"}', 202);
        }));
    await tester.pumpWidget(CupertinoApp(
        home: LoginPage(
            api: api,
            onPhoneLogin: (phone, code,
                {invitationCode = '',
                termsAccepted = false,
                shouldContinue}) async {
              phoneLogins++;
              throw const LoginStageException('matrix_session');
            })));
    await tester.pumpAndSettle();
    await tester.tap(find.text('手机号登录'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('auth-login-phone')), '13800000001');
    await tester.enterText(find.byKey(const Key('auth-login-code')), '123456');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.byKey(const Key('auth-agreement-checkbox')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('auth-agreement-checkbox')));
    await tester.pump();
    await tester.ensureVisible(find.widgetWithText(ModernActionButton, '登录'));
    await tester.tap(find.widgetWithText(ModernActionButton, '登录'));
    await tester.pumpAndSettle();

    expect(phoneLogins, 1);
    expect(find.textContaining('原验证码不可再次提交'), findsOneWidget);
    final codeField = tester.widget<CupertinoTextField>(find.descendant(
      of: find.byKey(const Key('auth-login-code')),
      matching: find.byType(CupertinoTextField),
    ));
    expect(codeField.controller?.text, isEmpty);
    expect(find.widgetWithText(ModernActionButton, '重试'), findsNothing);
    expect(otpRequests, 0);
    await tester
        .ensureVisible(find.widgetWithText(ModernActionButton, '重新获取验证码'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ModernActionButton>(
                find.widgetWithText(ModernActionButton, '重新获取验证码'))
            .onPressed,
        isNotNull);
    await tester.tap(find.widgetWithText(ModernActionButton, '重新获取验证码'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(phoneLogins, 1);
    expect(otpRequests, 1);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
  });
  testWidgets('rejected code cannot silently replay and does not auto resend',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    SharedPreferences.setMockInitialValues({});
    var logins = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.invalid'),
        sessionStore: SecureSessionStore(_MemoryStore()));
    await tester.pumpWidget(CupertinoApp(
        home: LoginPage(
            api: api,
            onPhoneLogin: (phone, code,
                {invitationCode = '',
                termsAccepted = false,
                shouldContinue}) async {
              logins++;
              if (logins == 1) {
                throw const BusinessApiException(
                    statusCode: 400, code: 'OTP_INVALID', message: '验证码无效或已过期');
              }
            })));
    await tester.pumpAndSettle();
    await tester.tap(find.text('手机号登录'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('auth-login-phone')), '13800000001');
    await tester.enterText(find.byKey(const Key('auth-login-code')), '111111');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.byKey(const Key('auth-agreement-checkbox')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('auth-agreement-checkbox')));
    await tester.pump();
    await tester.ensureVisible(find.widgetWithText(ModernActionButton, '登录'));
    await tester.tap(find.widgetWithText(ModernActionButton, '登录'));
    await tester.pumpAndSettle();
    expect(logins, 1);
    expect(find.widgetWithText(ModernActionButton, '重试'), findsNothing);
    expect(find.textContaining('原验证码不可再次提交'), findsOneWidget);
    final codeField = tester.widget<CupertinoTextField>(find.descendant(
        of: find.byKey(const Key('auth-login-code')),
        matching: find.byType(CupertinoTextField)));
    expect(codeField.controller?.text, isEmpty);
    expect(find.widgetWithText(ModernActionButton, '重新获取验证码'), findsOneWidget);
    expect(logins, 1);
  });
  testWidgets('verified new phone can add invitation without another SMS',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    SharedPreferences.setMockInitialValues({});
    var initialLogins = 0;
    var invitationContinuations = 0;
    var smsRequests = 0;
    var authenticated = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.invalid'),
        sessionStore: SecureSessionStore(_MemoryStore()),
        client: MockClient((_) async {
          smsRequests++;
          return http.Response('{"status":"accepted"}', 202);
        }));
    await tester.pumpWidget(CupertinoApp(
        home: LoginPage(
            api: api,
            onPhoneLogin: (phone, code,
                {invitationCode = '',
                termsAccepted = false,
                shouldContinue}) async {
              initialLogins++;
              throw const PhoneInvitationContinuationRequired(
                  ticket: 'opaque-verified-ticket-with-enough-length',
                  issue: PhoneInvitationIssue.required);
            },
            onPhoneInvitationContinue: (phone, ticket, invitationCode,
                {termsAccepted = false, shouldContinue}) async {
              invitationContinuations++;
              expect(phone, '13800000001');
              expect(ticket, 'opaque-verified-ticket-with-enough-length');
              expect(invitationCode,
                  invitationContinuations == 1 ? 'BAD-INVITE' : 'GOOD-INVITE');
              expect(termsAccepted, true);
              if (invitationContinuations == 1) {
                throw const PhoneInvitationContinuationRequired(
                    ticket: 'opaque-verified-ticket-with-enough-length',
                    issue: PhoneInvitationIssue.invalid);
              }
            },
            onAuthenticated: () async => authenticated++)));
    await tester.pumpAndSettle();
    await _submitPhoneCode(tester);
    expect(initialLogins, 1);
    expect(invitationContinuations, 0);
    expect(smsRequests, 0);
    expect(find.textContaining('验证码已通过'), findsOneWidget);
    expect(find.widgetWithText(ModernActionButton, '完成注册'), findsOneWidget);
    final codeField = tester.widget<CupertinoTextField>(find.descendant(
        of: find.byKey(const Key('auth-login-code')),
        matching: find.byType(CupertinoTextField)));
    expect(codeField.controller?.text, isEmpty);
    await tester.enterText(
        find.byKey(const Key('auth-login-invitation')), 'BAD-INVITE');
    await tester.ensureVisible(find.widgetWithText(ModernActionButton, '完成注册'));
    await tester.tap(find.widgetWithText(ModernActionButton, '完成注册'));
    await tester.pumpAndSettle();
    expect(find.textContaining('邀请码无效'), findsOneWidget);
    expect(find.widgetWithText(ModernActionButton, '完成注册'), findsOneWidget);
    expect(smsRequests, 0);
    await tester.enterText(
        find.byKey(const Key('auth-login-invitation')), 'GOOD-INVITE');
    await tester.tap(find.widgetWithText(ModernActionButton, '完成注册'));
    await tester.pumpAndSettle();
    expect(initialLogins, 1);
    expect(invitationContinuations, 2);
    expect(authenticated, 1);
    expect(smsRequests, 0);
  });
  testWidgets('password Matrix failure never mentions phone code',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    SharedPreferences.setMockInitialValues({});
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.invalid'),
        sessionStore: SecureSessionStore(_MemoryStore()));
    await tester.pumpWidget(CupertinoApp(
        home: LoginPage(
            api: api,
            onLogin: (_, __) async =>
                throw const LoginStageException('matrix_session'))));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('auth-login-identity')), 'alice');
    await tester.enterText(
        find.byKey(const Key('auth-login-password')), 'password');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.byKey(const Key('auth-agreement-checkbox')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('auth-agreement-checkbox')));
    await tester.pump();
    await tester.ensureVisible(find.widgetWithText(ModernActionButton, '登录'));
    await tester.tap(find.widgetWithText(ModernActionButton, '登录'));
    await tester.pumpAndSettle();
    expect(find.textContaining('重新获取验证码'), findsNothing);
    expect(find.widgetWithText(ModernActionButton, '重试'), findsOneWidget);
  });

  for (final failure in <(String, Object)>[
    (
      'provisioning pending after OTP was accepted',
      const BusinessApiException(
          statusCode: 202,
          code: 'PHONE_PROVISIONING_PENDING',
          message: '账号仍在开通'),
    ),
    (
      'Matrix grant rejected after OTP was accepted',
      const BusinessApiException(
          statusCode: 429, code: 'MATRIX_LOGIN_RATE_LIMITED', message: '请稍后重试'),
    ),
    (
      'account selection failed after OTP was accepted',
      const LoginStageException('account_storage')
    ),
    (
      'phone login response timed out with unknown OTP outcome',
      TimeoutException('response lost')
    ),
    ('unexpected post-login failure', StateError('post-login failed')),
  ]) {
    testWidgets('${failure.$1} requires a new code without replay',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(393, 852);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      SharedPreferences.setMockInitialValues({});
      var submissions = 0;
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://example.invalid'),
          sessionStore: SecureSessionStore(_MemoryStore()));
      await tester.pumpWidget(CupertinoApp(
          home: LoginPage(
              api: api,
              onPhoneLogin: (phone, code,
                  {invitationCode = '',
                  termsAccepted = false,
                  shouldContinue}) async {
                submissions++;
                throw failure.$2;
              })));
      await tester.pumpAndSettle();
      await _submitPhoneCode(tester);
      expect(submissions, 1);
      expect(
          find.widgetWithText(ModernActionButton, '重新获取验证码'), findsOneWidget);
      expect(find.widgetWithText(ModernActionButton, '重试'), findsNothing);
      final codeField = tester.widget<CupertinoTextField>(find.descendant(
          of: find.byKey(const Key('auth-login-code')),
          matching: find.byType(CupertinoTextField)));
      expect(codeField.controller?.text, isEmpty);
    });
  }

  testWidgets('cancelled account switch cannot replay its consumed phone code',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    SharedPreferences.setMockInitialValues({});
    var submissions = 0;
    var cancellations = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.invalid'),
        sessionStore: SecureSessionStore(_MemoryStore()));
    await tester.pumpWidget(CupertinoApp(
        home: LoginPage(
            api: api,
            onPhoneLogin: (phone, code,
                {invitationCode = '',
                termsAccepted = false,
                shouldContinue}) async {
              submissions++;
              throw const MatrixAccountSwitchRequired(
                  fromMxid: '@old:example.invalid',
                  toMxid: '@new:example.invalid');
            },
            onCancelMatrixAccountSwitch: () async => cancellations++)));
    await tester.pumpAndSettle();
    await _submitPhoneCode(tester, settle: false);
    await tester.pump();
    expect(find.text('切换聊天账号'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(submissions, 1);
    expect(cancellations, 1);
    expect(find.widgetWithText(ModernActionButton, '重新获取验证码'), findsOneWidget);
  });

  testWidgets('post-login callback failure cannot replay a phone code',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    SharedPreferences.setMockInitialValues({});
    var submissions = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.invalid'),
        sessionStore: SecureSessionStore(_MemoryStore()));
    await tester.pumpWidget(CupertinoApp(
        home: LoginPage(
            api: api,
            onPhoneLogin: (phone, code,
                {invitationCode = '',
                termsAccepted = false,
                shouldContinue}) async {
              submissions++;
            },
            onAuthenticated: () async => throw StateError('startup failed'))));
    await tester.pumpAndSettle();
    await _submitPhoneCode(tester);
    expect(submissions, 1);
    expect(find.widgetWithText(ModernActionButton, '重新获取验证码'), findsOneWidget);
  });

  testWidgets('OTP response for a previous phone cannot unlock current phone',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    SharedPreferences.setMockInitialValues({});
    final otpResponse = Completer<http.Response>();
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.invalid'),
        sessionStore: SecureSessionStore(_MemoryStore()),
        client: MockClient((_) => otpResponse.future));
    await tester.pumpWidget(CupertinoApp(
        home: LoginPage(
            api: api,
            onPhoneLogin: (phone, code,
                    {invitationCode = '',
                    termsAccepted = false,
                    shouldContinue}) async =>
                throw TimeoutException('unknown'))));
    await tester.pumpAndSettle();
    await _submitPhoneCode(tester);
    expect(find.widgetWithText(ModernActionButton, '重新获取验证码'), findsOneWidget);
    await tester
        .ensureVisible(find.widgetWithText(ModernActionButton, '重新获取验证码'));
    await tester.tap(find.widgetWithText(ModernActionButton, '重新获取验证码'));
    await tester.pump();
    await tester.enterText(
        find.byKey(const Key('auth-login-phone')), '13800000002');
    otpResponse.complete(http.Response('{"status":"accepted"}', 202));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ModernActionButton, '重新获取验证码'), findsOneWidget);
  });
}

Future<void> _submitPhoneCode(WidgetTester tester, {bool settle = true}) async {
  await tester.tap(find.text('手机号登录'));
  await tester.pumpAndSettle();
  await tester.enterText(
      find.byKey(const Key('auth-login-phone')), '13800000001');
  await tester.enterText(find.byKey(const Key('auth-login-code')), '123456');
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(const Key('auth-agreement-checkbox')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('auth-agreement-checkbox')));
  await tester.pump();
  await tester.ensureVisible(find.widgetWithText(ModernActionButton, '登录'));
  await tester.tap(find.widgetWithText(ModernActionButton, '登录'));
  if (settle) await tester.pumpAndSettle();
}

class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
