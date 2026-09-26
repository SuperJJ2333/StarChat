import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/account_credentials_gateway.dart';
import 'package:liuhetong_mobile/core/business_api_error.dart';
import 'package:liuhetong_mobile/features/auth/password_change_page.dart';
import 'package:liuhetong_mobile/features/auth/email_rebind_page.dart';

class CredentialsFake implements AccountCredentialsGateway {
  final calls = <String>[];
  bool reject = false;
  Object? sendError;
  Object? rebindError;
  Completer<void>? resetCompletion;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<int> requestPasswordCode(
      {required String channel,
      required String target,
      required bool authenticated}) async {
    calls.add('request:$channel:$target:$authenticated');
    if (sendError != null) throw sendError!;
    return 60;
  }

  @override
  Future<String> verifyPasswordCode(
      {required String channel,
      required String target,
      required String code,
      required bool authenticated}) async {
    calls.add('verify');
    if (reject) throw StateError('invalid');
    return 'proof';
  }

  @override
  Future<void> resetPassword(
      {required String token,
      required String newPassword,
      required bool authenticated}) async {
    calls.add('reset:$token');
    await resetCompletion?.future;
  }

  @override
  Future<Map<String, dynamic>> requestEmailRebindOldCode() async {
    calls.add('old-request');
    return {'channel': 'phone', 'target': '138****0001'};
  }

  @override
  Future<void> verifyEmailRebindOldCode(String code) async {
    calls.add('old-confirm');
    if (reject) throw StateError('invalid');
  }

  @override
  Future<int> requestEmailRebindNewCode(String email) async {
    calls.add('new-request');
    return 60;
  }

  @override
  Future<void> confirmEmailRebind(
      {required String email, required String code}) async {
    calls.add('new-confirm');
    if (rebindError != null) throw rebindError!;
  }
}

Finder input(String key) => find.descendant(
    of: find.byKey(Key(key)), matching: find.byType(CupertinoTextField));
void main() {
  testWidgets(
      'expired old email proof returns to identity verification and keeps new-email draft',
      (tester) async {
    final gateway = CredentialsFake();
    await tester
        .pumpWidget(CupertinoApp(home: EmailRebindPage(gateway: gateway)));
    await tester.enterText(input('email-rebind-code'), '123456');
    await tester.tap(find.byKey(const Key('email-rebind-confirm')));
    await tester.pumpAndSettle();
    await tester.enterText(input('email-rebind-email'), 'new@example.test');
    await tester.enterText(input('email-rebind-code'), '123456');
    gateway.rebindError = const BusinessApiException(
        statusCode: 409,
        code: 'REBIND_OLD_VERIFICATION_REQUIRED',
        message: '请重新验证当前身份');
    await tester.tap(find.byKey(const Key('email-rebind-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('email-rebind-email')), findsNothing);
    expect(find.text('验证当前身份'), findsOneWidget);
    gateway.rebindError = null;
    await tester.enterText(input('email-rebind-code'), '123456');
    await tester.tap(find.byKey(const Key('email-rebind-confirm')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CupertinoTextField>(input('email-rebind-email'))
            .controller!
            .text,
        'new@example.test');
    await tester.enterText(input('email-rebind-code'), '123456');
    await tester.tap(find.byKey(const Key('email-rebind-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('邮箱已更新'), findsOneWidget);
  });
  testWidgets(
      'a single verified binding renders without a segmented-control assertion',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
        home: PasswordChangePage(
            gateway: CredentialsFake(),
            authenticated: true,
            security: const AccountSecurityData(
                maskedEmail: 'a***@example.test',
                maskedPhone: null,
                emailBound: true,
                phoneBound: false,
                emailVerified: true,
                phoneVerified: false),
            onCompleted: () async {})));
    expect(tester.takeException(), isNull);
    expect(find.text('已绑定邮箱'), findsOneWidget);
  });
  testWidgets(
      'late successful reset completes lifecycle once after page disposal',
      (tester) async {
    final gateway = CredentialsFake()..resetCompletion = Completer<void>();
    var completed = 0;
    await tester.pumpWidget(CupertinoApp(
        home: PasswordChangePage(
            gateway: gateway,
            onCompleted: () async {
              completed++;
            })));
    await tester.enterText(input('password-target'), 'bound@example.test');
    await tester.enterText(input('password-code'), '123456');
    await tester.tap(find.byKey(const Key('password-verify')));
    await tester.pumpAndSettle();
    await tester.enterText(input('password-new'), 'new-password-123');
    await tester.enterText(input('password-confirmation'), 'new-password-123');
    await tester.tap(find.byKey(const Key('password-submit')));
    await tester.pump(const Duration(seconds: 9));
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    gateway.resetCompletion!.complete();
    await tester.pump();
    expect(completed, 1);
  });
  testWidgets('expired proof offers verification again within the page',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
        home: PasswordChangePage(
            gateway: CredentialsFake(), onCompleted: () async {})));
    await tester.enterText(input('password-target'), 'bound@example.test');
    await tester.enterText(input('password-code'), '123456');
    await tester.tap(find.byKey(const Key('password-verify')));
    await tester.pumpAndSettle();
    await tester.enterText(input('password-new'), 'expired-password-123');
    await tester.enterText(
        input('password-confirmation'), 'expired-password-123');
    await tester.pump(const Duration(minutes: 5));
    expect(find.byKey(const Key('password-verify')), findsOneWidget);
    expect(find.byKey(const Key('password-new')), findsNothing);
    await tester.enterText(input('password-code'), '123456');
    await tester.tap(find.byKey(const Key('password-verify')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CupertinoTextField>(input('password-new'))
            .controller!
            .text,
        isEmpty);
    expect(
        tester
            .widget<CupertinoTextField>(input('password-confirmation'))
            .controller!
            .text,
        isEmpty);
  });
  testWidgets('password proof is required and failure retains OTP draft',
      (tester) async {
    final gateway = CredentialsFake()..reject = true;
    var completed = 0;
    await tester.pumpWidget(CupertinoApp(
        home: PasswordChangePage(
            gateway: gateway,
            onCompleted: () async {
              completed++;
            })));
    expect(gateway.calls, isEmpty);
    await tester.enterText(input('password-target'), 'bound@example.test');
    await tester.enterText(input('password-code'), '123456');
    await tester.tap(find.byKey(const Key('password-verify')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('password-new')), findsNothing);
    expect(
        tester
            .widget<CupertinoTextField>(input('password-code'))
            .controller!
            .text,
        '123456');
    gateway.reject = false;
    await tester.tap(find.byKey(const Key('password-verify')));
    await tester.pumpAndSettle();
    await tester.enterText(input('password-new'), 'new-password-123');
    await tester.enterText(input('password-confirmation'), 'different');
    await tester.tap(find.byKey(const Key('password-submit')));
    await tester.pumpAndSettle();
    expect(gateway.calls.where((x) => x.startsWith('reset:')), isEmpty);
    await tester.enterText(input('password-confirmation'), 'new-password-123');
    await tester.tap(find.byKey(const Key('password-submit')));
    await tester.pumpAndSettle();
    expect(gateway.calls.last, 'reset:proof');
    expect(completed, 1);
  });
  testWidgets(
      'lost OTP response keeps cooldown and never retries automatically',
      (tester) async {
    final gateway = CredentialsFake()..sendError = TimeoutException('unknown');
    await tester.pumpWidget(CupertinoApp(
        home: PasswordChangePage(gateway: gateway, onCompleted: () async {})));
    await tester.enterText(input('password-target'), 'bound@example.test');
    await tester.tap(find.byKey(const Key('password-send-code')));
    await tester.pump();
    expect(find.text('60s'), findsOneWidget);
    expect(gateway.calls, hasLength(1));
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
  });
  testWidgets('email rebind requires old proof before new email',
      (tester) async {
    final gateway = CredentialsFake()..reject = true;
    await tester
        .pumpWidget(CupertinoApp(home: EmailRebindPage(gateway: gateway)));
    expect(gateway.calls, isEmpty);
    expect(find.byKey(const Key('email-rebind-email')), findsNothing);
    await tester.enterText(input('email-rebind-code'), '123456');
    await tester.tap(find.byKey(const Key('email-rebind-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('email-rebind-email')), findsNothing);
    gateway.reject = false;
    await tester.tap(find.byKey(const Key('email-rebind-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('email-rebind-email')), findsOneWidget);
  });
}
