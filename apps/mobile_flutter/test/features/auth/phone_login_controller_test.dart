import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/business_api_error.dart';
import 'package:liuhetong_mobile/core/business_phone_contracts.dart';
import 'package:liuhetong_mobile/features/auth/phone_login_controller.dart';

/// ADR-0075 UI 批次：短信登录状态机回归。
///
/// 纪律：超时/发送失败绝不显示"未发送"、绝不自动重发；凭据错误计入服务端
/// 尝试不自动重试；重发冷却 60 秒本地计时。
void main() {
  final fixedNow = DateTime(2026, 9, 23, 12, 0, 0);
  late FakePhoneGateway gateway;
  late PhoneLoginController controller;
  var now = fixedNow;

  setUp(() {
    gateway = FakePhoneGateway();
    now = fixedNow;
    controller = PhoneLoginController(
      gateway: gateway,
      deviceKey: 'device-key-1',
      deviceName: 'Mi 6',
      now: () => now,
    );
  });

  test('requestOtp succeeds, enters cooldown 60s, blocks immediate re-request',
      () async {
    expect(await controller.requestOtp('+8613800000001'), isTrue);
    expect(controller.state.status, PhoneLoginStatus.otpSent);
    expect(controller.state.resendAfterSeconds, 60);
    expect(gateway.otpRequests, ['+8613800000001']);

    final before = gateway.otpRequests.length;
    final again = await controller.requestOtp('+8613800000001');
    expect(again, isFalse, reason: '冷却期内不得重复请求');
    expect(gateway.otpRequests.length, before);
  });

  test(
      'send failure shows unavailable, never claims "not sent", no auto resend',
      () async {
    gateway.otpError = BusinessApiException(
        code: 'SMS_SEND_REJECTED', message: '短信发送被供应商拒绝', statusCode: 503);
    expect(await controller.requestOtp('+8613800000001'), isFalse);
    expect(controller.state.status, PhoneLoginStatus.failed);
    expect(controller.state.message, isNotNull);
    expect(gateway.otpRequests.length, 1, reason: '失败后不自动重发');
  });

  test('SMS rate limit remains an OTP warning rather than login rate limit',
      () async {
    gateway.otpError = const BusinessApiException(
        code: 'OTP_SEND_RATE_LIMITED',
        message: '发送过于频繁',
        statusCode: 429,
        retryAfterSeconds: 60);
    expect(await controller.requestOtp('13800000001'), isFalse);
    expect(controller.state.message, '发送过于频繁，请稍后再试');
    expect(controller.state.loginRetryAfterSeconds, isNull);
    expect(gateway.otpRequests.length, 1);
  });

  test('correct code succeeds and lands session via gateway', () async {
    await controller.requestOtp('+8613800000001');
    expect(await controller.submit('+8613800000001', '243697'), isTrue);
    expect(controller.state.status, PhoneLoginStatus.succeeded);
    expect(gateway.loginAttempts.last['code'], '243697');
  });

  test('wrong code fails once without automatic retry (server counts attempts)',
      () async {
    await controller.requestOtp('+8613800000001');
    gateway.loginError = BusinessApiException(
        code: 'CREDENTIALS_INVALID', message: '账号或验证码错误', statusCode: 401);
    expect(await controller.submit('+8613800000001', '000000'), isFalse);
    expect(gateway.loginAttempts.length, 1, reason: '凭据错误不自动重试');
    expect(controller.state.message, '手机号或验证码错误');
  });

  test('verify unavailable does not burn the attempt message', () async {
    await controller.requestOtp('+8613800000001');
    gateway.loginError = BusinessApiException(
        code: 'SMS_VERIFY_UNAVAILABLE', message: '校验暂不可用', statusCode: 503);
    expect(await controller.submit('+8613800000001', '123456'), isFalse);
    expect(controller.state.message, contains('未计入尝试'));
    expect(gateway.loginAttempts.length, 1);
  });

  test('cooldown expires after 60 seconds and allows re-request', () async {
    await controller.requestOtp('+8613800000001');
    now = fixedNow.add(const Duration(seconds: 61));
    expect(controller.canRequestOtp, isTrue);
  });
}

class FakePhoneGateway implements PhoneAuthGateway {
  final otpRequests = <String>[];
  final loginAttempts = <Map<String, dynamic>>[];
  BusinessApiException? otpError;
  BusinessApiException? loginError;
  bool otpResult = true;

  @override
  Future<void> requestPhoneLoginOtp(String phone) async {
    otpRequests.add(phone);
    final error = otpError;
    if (error != null) throw error;
  }

  @override
  Future<Map<String, dynamic>> phoneLogin({
    required String phone,
    required String code,
    required String deviceKey,
    required String deviceName,
    String invitationCode = '',
    bool termsAccepted = false,
    bool Function()? shouldContinue,
  }) async {
    loginAttempts.add({'phone': phone, 'code': code});
    final error = loginError;
    if (error != null) throw error;
    return {
      'access_token': 'at',
      'refresh_token': 'rt',
      'matrix_user_id': '@x:y',
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
