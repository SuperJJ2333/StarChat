import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/business_api_error.dart';
import '../../core/business_phone_contracts.dart';

/// ADR-0075：短信验证码登录状态机（UI 批次）。
///
/// 纪律（复审第三/五轮口径）：
/// - OTP 请求与验证共用 8 秒预算；超时＝结果未知——提示"请稍后查询/重试"，
/// 绝不显示"未发送"，也绝不自动重发（服务端 10 分钟 ≤3 条限频）。
/// - 重发冷却 60 秒（与服务端 resend 口径一致），本地计时，不请求服务端。
/// - 错误映射：CREDENTIALS_INVALID/OTP_INVALID → 凭据错误；OTP_SEND_RATE_LIMITED
///   → 冷却提示；PHONE_AUTH_DISABLED/SMS_NOT_CONFIGURED/SMS_SEND_REJECTED/
///   SMS_VERIFY_UNAVAILABLE/SMS_PROVIDER_TIMEOUT → 服务暂不可用。
enum PhoneLoginStatus {
  idle,
  otpSending,
  otpSent,
  verifying,
  succeeded,
  failed
}

final class PhoneLoginState {
  const PhoneLoginState(
    this.status, {
    this.message,
    this.resendAfterSeconds = 0,
  });

  final PhoneLoginStatus status;
  final String? message;
  final int resendAfterSeconds;

  bool get canSubmitCode =>
      status == PhoneLoginStatus.otpSent || status == PhoneLoginStatus.failed;
}

final class PhoneLoginController extends ChangeNotifier {
  PhoneLoginController({
    required this.gateway,
    required this.deviceKey,
    required this.deviceName,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final PhoneAuthGateway gateway;
  final String deviceKey;
  final String deviceName;
  final DateTime Function() _now;

  PhoneLoginState state = const PhoneLoginState(PhoneLoginStatus.idle);
  DateTime? _cooldownUntil;
  Timer? _cooldownTimer;
  bool _disposed = false;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  bool get canRequestOtp =>
      state.status != PhoneLoginStatus.otpSending &&
      state.status != PhoneLoginStatus.verifying &&
      (_cooldownUntil == null || !_now().isBefore(_cooldownUntil!));

  @override
  void dispose() {
    _disposed = true;
    _cooldownTimer?.cancel();
    super.dispose();
  }

  /// 请求验证码。超时/失败不改变"是否已发送"的事实——提示用户稍后重试，
  /// 由服务端限频兜底；本地不自动重发。
  Future<bool> requestOtp(String phone) async {
    if (state.status == PhoneLoginStatus.otpSending ||
        state.status == PhoneLoginStatus.verifying) {
      return false;
    }
    if (_cooldownUntil != null && _now().isBefore(_cooldownUntil!)) {
      final remain = _cooldownUntil!.difference(_now()).inSeconds.clamp(0, 60);
      state = PhoneLoginState(PhoneLoginStatus.otpSent,
          message: '请 $remain 秒后再请求验证码', resendAfterSeconds: remain);
      notifyListeners();
      return false;
    }
    _cooldownUntil = _now().add(const Duration(seconds: 60));
    _startCooldownTicker();
    state = const PhoneLoginState(PhoneLoginStatus.otpSending,
        resendAfterSeconds: 60);
    notifyListeners();
    try {
      await gateway.requestPhoneLoginOtp(phone);
    } on Exception catch (error) {
      state = PhoneLoginState(PhoneLoginStatus.failed,
          resendAfterSeconds: 60,
          message: _messageFor(error, fallback: '短信发送结果待确认，请检查短信并稍后重试'));
      notifyListeners();
      return false;
    }
    _cooldownUntil = _now().add(const Duration(seconds: 60));
    state =
        const PhoneLoginState(PhoneLoginStatus.otpSent, resendAfterSeconds: 60);
    notifyListeners();
    _startCooldownTicker();
    return true;
  }

  /// 提交验证码仅发送一次；凭据类错误计入服务端五次尝试。
  Future<bool> submit(String phone, String code) async {
    if (state.status == PhoneLoginStatus.verifying) return false;
    state = const PhoneLoginState(PhoneLoginStatus.verifying);
    notifyListeners();
    try {
      await gateway.phoneLogin(
        phone: phone,
        code: code,
        deviceKey: deviceKey,
        deviceName: deviceName,
      );
    } on Exception catch (error) {
      final code_ = _errorCode(error);
      if (code_ == 'SMS_VERIFY_UNAVAILABLE' ||
          code_ == 'SMS_PROVIDER_TIMEOUT') {
        state = const PhoneLoginState(PhoneLoginStatus.failed,
            message: '校验暂不可用，请稍后重试（本次未计入尝试）');
        notifyListeners();
        return false;
      }
      state = PhoneLoginState(PhoneLoginStatus.failed,
          message: _messageFor(error, fallback: '账号或验证码错误'));
      notifyListeners();
      return false;
    }
    state = const PhoneLoginState(PhoneLoginStatus.succeeded);
    notifyListeners();
    return true;
  }

  void _startCooldownTicker() {
    if (_disposed) return;
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_cooldownUntil == null) {
        timer.cancel();
        return;
      }
      final remain = _cooldownUntil!.difference(_now()).inSeconds.clamp(0, 60);
      if (state.status != PhoneLoginStatus.otpSending) {
        state = PhoneLoginState(state.status,
            message: state.message, resendAfterSeconds: remain);
        notifyListeners();
      }
      if (remain == 0) timer.cancel();
    });
  }

  String _messageFor(Exception error, {required String fallback}) {
    switch (_errorCode(error)) {
      case 'CREDENTIALS_INVALID':
      case 'OTP_INVALID':
        return '手机号或验证码错误';
      case 'OTP_SEND_RATE_LIMITED':
        return '发送过于频繁，请稍后再试';
      case 'OTP_SEND_REJECTED':
      case 'SMS_SEND_REJECTED':
      case 'SMS_SEND_FAILED':
      case 'SMS_NOT_CONFIGURED':
      case 'PHONE_AUTH_DISABLED':
        return '短信服务暂不可用，请联系客服';
      case 'ACCOUNT_NOT_ACTIVE':
      case 'ACCOUNT_SUSPENDED':
        return '账号状态异常，请联系客服';
    }
    return fallback;
  }

  String? _errorCode(Exception error) {
    // 服务端异常以稳定 code 为准（toString 只有中文文案）。
    if (error is BusinessApiException) return error.code;
    final text = error.toString();
    final match = RegExp(r"code:?\s*'?[A-Z][A-Z0-9_]{3,}'?").firstMatch(text);
    return match
        ?.group(0)
        ?.replaceAll(RegExp(r"code:?\s*'"), '')
        .replaceAll("'", '');
  }
}
