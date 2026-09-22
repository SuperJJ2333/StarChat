import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_error.dart';
import 'package:liuhetong_mobile/core/business_phone_contracts.dart';
import 'package:liuhetong_mobile/features/auth/phone_rebind_page.dart';

class PhoneGateway implements PhoneAuthGateway {
  final calls = <String>[];
  bool reject = true;
  Object? requestError;
  String? channel = 'email';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<Map<String, dynamic>> rebindOldRequest() async {
    calls.add('old-request');
    if (requestError != null) throw requestError!;
    return {if (channel != null) 'channel': channel};
  }

  @override
  Future<void> rebindOldConfirm({required String code}) async {
    calls.add('old-confirm');
    if (reject) {
      throw const BusinessApiException(
          statusCode: 400, code: 'OTP_INVALID', message: '验证码错误');
    }
  }

  @override
  Future<void> rebindNewRequest({required String phone}) async {
    calls.add('new-request');
  }

  @override
  Future<void> rebindNewConfirm(
      {required String phone, required String code}) async {
    calls.add('new-confirm');
  }
}

void main() {
  for (final entry in <(Object, String)>[
    (
      const BusinessApiException(
          statusCode: 404, code: 'BUSINESS_REQUEST_FAILED', message: '业务请求失败'),
      '当前服务暂不支持手机号换绑，请联系客服'
    ),
    (
      const BusinessApiException(
          statusCode: 405, code: 'BUSINESS_REQUEST_FAILED', message: '业务请求失败'),
      '当前服务暂不支持手机号换绑，请联系客服'
    ),
    (
      const BusinessApiException(
          statusCode: 503, code: 'PHONE_AUTH_DISABLED', message: '手机号功能未开启'),
      '手机号功能暂未开启，请联系客服'
    ),
    (
      const BusinessApiException(
          statusCode: 503, code: 'SMS_NOT_CONFIGURED', message: '短信服务未配置'),
      '短信服务暂不可用，请联系客服'
    ),
    (
      const BusinessApiException(
          statusCode: 503, code: 'BUSINESS_REQUEST_FAILED', message: '业务请求失败'),
      '验证服务暂不可用，请稍后重试或联系客服'
    ),
    (TimeoutException('lost response'), '请求结果待确认，请稍后重试或联系客服'),
  ]) {
    testWidgets('old request classifies ${entry.$1.runtimeType} ${entry.$2}',
        (tester) async {
      final api = PhoneGateway()..requestError = entry.$1;
      await tester.pumpWidget(CupertinoApp(home: PhoneRebindPage(api: api)));
      await tester.tap(find.text('获取验证码'));
      await tester.pumpAndSettle();
      expect(find.text(entry.$2), findsOneWidget);
      expect(find.textContaining('验证码已发送'), findsNothing);
      expect(find.byKey(const Key('phone-rebind-phone')), findsNothing);
      expect(api.calls, ['old-request']);
      expect(find.text('60s'), findsOneWidget);
      await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    });
  }
  testWidgets(
      'unknown response channel never invents phone or email destination',
      (tester) async {
    final api = PhoneGateway()..channel = null;
    await tester.pumpWidget(CupertinoApp(home: PhoneRebindPage(api: api)));
    await tester.tap(find.text('获取验证码'));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法确认验证方式，请稍后重试或联系客服'), findsOneWidget);
    expect(find.textContaining('验证码已发送'), findsNothing);
    expect(api.calls, ['old-request']);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
  });
  testWidgets('rebind requires old verification and uses wallet fishbone steps',
      (tester) async {
    final api = PhoneGateway();
    await tester.pumpWidget(CupertinoApp(home: PhoneRebindPage(api: api)));
    expect(api.calls, isEmpty);
    expect(find.byKey(const Key('phone-rebind-step-dot-0')), findsOneWidget);
    expect(find.byKey(const Key('phone-rebind-phone')), findsNothing);
    await tester.enterText(
        find.descendant(
            of: find.byKey(const Key('phone-rebind-code')),
            matching: find.byType(CupertinoTextField)),
        '123456');
    await tester.tap(find.byKey(const Key('phone-rebind-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('验证码错误'), findsOneWidget);
    expect(find.byKey(const Key('phone-rebind-phone')), findsNothing);
    api.reject = false;
    await tester.tap(find.byKey(const Key('phone-rebind-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('phone-rebind-step-check-0')), findsOneWidget);
    await tester.enterText(
        find.descendant(
            of: find.byKey(const Key('phone-rebind-phone')),
            matching: find.byType(CupertinoTextField)),
        '13800000001');
    await tester.tap(find.text('获取验证码'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.descendant(
            of: find.byKey(const Key('phone-rebind-code')),
            matching: find.byType(CupertinoTextField)),
        '654321');
    await tester.tap(find.byKey(const Key('phone-rebind-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('手机号已更新'), findsOneWidget);
    expect(api.calls,
        ['old-confirm', 'old-confirm', 'new-request', 'new-confirm']);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
  });
}
