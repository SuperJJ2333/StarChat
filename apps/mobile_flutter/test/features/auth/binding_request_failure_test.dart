import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_error.dart';
import 'package:liuhetong_mobile/features/auth/email_rebind_page.dart';
import 'package:liuhetong_mobile/features/auth/phone_rebind_page.dart';
import 'account_credentials_test.dart' show CredentialsFake;
import 'phone_rebind_test.dart' show PhoneGateway;

class RejectedPhoneGateway extends PhoneGateway {
  Object? newSendError;
  final targets = <String>[];
  @override
  Future<void> rebindNewRequest({required String phone}) async {
    targets.add(phone);
    if (newSendError != null) throw newSendError!;
  }
}

class RejectedEmailGateway extends CredentialsFake {
  Object? newSendError;
  final targets = <String>[];
  @override
  Future<int> requestEmailRebindNewCode(String email) async {
    targets.add(email);
    if (newSendError != null) throw newSendError!;
    return 60;
  }
}

Finder input(String key) => find.descendant(
    of: find.byKey(Key(key)), matching: find.byType(CupertinoTextField));

void main() {
  for (final code in [
    'TAKEN',
    'UNCHANGED',
    'INVALID',
    'REBIND_OLD_VERIFICATION_REQUIRED',
    'SMS_NOT_CONFIGURED',
    'PHONE_AUTH_DISABLED',
    'SMS_SEND_REJECTED',
    'SMS_SEND_FAILED',
  ]) {
    for (final phone in [true, false]) {
      testWidgets(
          '${phone ? 'phone' : 'email'} rejected $code allows immediate correction',
          (tester) async {
        final api = RejectedPhoneGateway()..reject = false;
        final gateway = RejectedEmailGateway();
        await tester.pumpWidget(CupertinoApp(
            home: phone
                ? PhoneRebindPage(api: api)
                : EmailRebindPage(gateway: gateway)));
        final prefix = phone ? 'phone' : 'email';
        await tester.enterText(input('$prefix-rebind-code'), '123456');
        await tester.tap(find.byKey(Key('$prefix-rebind-confirm')));
        await tester.pumpAndSettle();
        final targetKey = '$prefix-rebind-${phone ? 'phone' : 'email'}';
        final target = phone ? '13800000001' : 'taken@example.test';
        final errorCode = ['TAKEN', 'UNCHANGED', 'INVALID'].contains(code)
            ? '${prefix.toUpperCase()}_$code'
            : code;
        final error = BusinessApiException(
            statusCode: code == 'INVALID'
                ? 422
                : code.startsWith('SMS_') || code == 'PHONE_AUTH_DISABLED'
                    ? 503
                    : 409,
            code: errorCode,
            message: '请求未被接受');
        api.newSendError = error;
        gateway.newSendError = error;
        await tester.enterText(input(targetKey), target);
        await tester.tap(find.text('获取验证码'));
        await tester.pumpAndSettle();
        expect(find.textContaining(RegExp(r'^\d+s$')), findsNothing);
        expect(find.text('获取验证码'), findsOneWidget);
        // Email expired proof intentionally returns to old verification.
        if (!phone && code == 'REBIND_OLD_VERIFICATION_REQUIRED') {
          expect(find.text('验证当前身份'), findsOneWidget);
          await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
          return;
        }
        expect(tester.widget<CupertinoTextField>(input(targetKey)).enabled,
            isTrue);
        final replacement = phone ? '13900000002' : 'free@example.test';
        await tester.enterText(input(targetKey), replacement);
        api.newSendError = null;
        gateway.newSendError = null;
        await tester.tap(find.text('获取验证码'));
        await tester.pumpAndSettle();
        expect(phone ? api.targets : gateway.targets, [target, replacement]);
        expect(find.textContaining(RegExp(r'^\d+s$')), findsOneWidget);
        await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
      });
    }
  }
  for (final error in [
    TimeoutException('unknown outcome'),
    const BusinessApiException(
        statusCode: 503, code: 'SMS_PROVIDER_TIMEOUT', message: '待确认'),
    const BusinessApiException(
        statusCode: 500, code: 'BUSINESS_REQUEST_FAILED', message: '业务请求失败'),
    const BusinessApiException(
        statusCode: 408, code: 'REQUEST_TIMEOUT', message: '待确认'),
  ]) {
    for (final phone in [true, false]) {
      testWidgets(
          '${phone ? 'phone' : 'email'} unknown send retains cooldown $error',
          (tester) async {
        final api = RejectedPhoneGateway()..reject = false;
        final gateway = RejectedEmailGateway();
        await tester.pumpWidget(CupertinoApp(
            home: phone
                ? PhoneRebindPage(api: api)
                : EmailRebindPage(gateway: gateway)));
        final prefix = phone ? 'phone' : 'email';
        await tester.enterText(input('$prefix-rebind-code'), '123456');
        await tester.tap(find.byKey(Key('$prefix-rebind-confirm')));
        await tester.pumpAndSettle();
        api.newSendError = error;
        gateway.newSendError = error;
        final targetKey = '$prefix-rebind-${phone ? 'phone' : 'email'}';
        await tester.enterText(
            input(targetKey), phone ? '13800000001' : 'a@example.test');
        await tester.tap(find.text('获取验证码'));
        await tester.pumpAndSettle();
        expect(find.textContaining(RegExp(r'^\d+s$')), findsOneWidget);
        expect(tester.widget<CupertinoTextField>(input(targetKey)).enabled,
            isFalse);
        expect(phone ? api.targets : gateway.targets, hasLength(1));
        await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
      });
    }
  }
}
