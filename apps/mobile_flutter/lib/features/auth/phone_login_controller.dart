import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/business_api_error.dart';
import '../../core/business_phone_contracts.dart';
import 'otp_cooldown.dart';

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
    this.loginRetryAfterSeconds,
  });

  final PhoneLoginStatus status;
  final String? message;
  final int resendAfterSeconds;
  final int? loginRetryAfterSeconds;

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
  PhoneInvitationContinuationRequired? invitationContinuation;
  late final OtpCooldown _cooldown = OtpCooldown(gateway, now: _now);
  void selectPhone(String phone) {
    _cooldown.bind(purpose: 'login', channel: 'phone', target: phone);
    _refreshCooldown();
    _startCooldownTicker();
  }

  Timer? _cooldownTimer;
  bool _disposed = false;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  bool get canRequestOtp =>
      state.status != PhoneLoginStatus.otpSending &&
      state.status != PhoneLoginStatus.verifying &&
      _cooldown.remaining == 0;

  @override
  void dispose() {
    _disposed = true;
    _cooldownTimer?.cancel();
    super.dispose();
  }

  /// 请求验证码。超时/失败不改变"是否已发送"的事实——提示用户稍后重试，
  /// 由服务端限频兜底；本地不自动重发。
  Future<bool> requestOtp(String phone) async {
    selectPhone(phone);
    invitationContinuation = null;
    if (state.status == PhoneLoginStatus.otpSending ||
        state.status == PhoneLoginStatus.verifying) {
      return false;
    }
    if (_cooldown.remaining > 0) {
      final remain = _cooldown.remaining;
      state = PhoneLoginState(PhoneLoginStatus.otpSent,
          message: '请 $remain 秒后再请求验证码', resendAfterSeconds: remain);
      notifyListeners();
      return false;
    }
    _cooldown.reserve();
    final requestedCooldown = _cooldown.snapshot();
    _startCooldownTicker();
    state = const PhoneLoginState(PhoneLoginStatus.otpSending,
        resendAfterSeconds: 60);
    notifyListeners();
    try {
      await gateway.requestPhoneLoginOtp(phone);
    } on Exception catch (error) {
      if (error is BusinessApiException && error.statusCode == 429) {
        requestedCooldown.extend(error.retryAfterSeconds ?? 60);
      }
      state = PhoneLoginState(PhoneLoginStatus.failed,
          resendAfterSeconds: _cooldown.remaining,
          message: _messageFor(error, fallback: '短信发送结果待确认，请检查短信并稍后重试'));
      notifyListeners();
      return false;
    }
    state = PhoneLoginState(PhoneLoginStatus.otpSent,
        resendAfterSeconds: _cooldown.remaining);
    notifyListeners();
    _startCooldownTicker();
    return true;
  }

  /// 提交验证码仅发送一次；凭据类错误计入服务端五次尝试。
  Future<bool> submit(String phone, String code,
      {String invitationCode = '',
      bool termsAccepted = false,
      bool Function()? shouldContinue}) async {
    if (state.status == PhoneLoginStatus.verifying) return false;
    invitationContinuation = null;
    state = const PhoneLoginState(PhoneLoginStatus.verifying);
    notifyListeners();
    try {
      await gateway.phoneLogin(
        phone: phone,
        code: code,
        invitationCode: invitationCode,
        termsAccepted: termsAccepted,
        shouldContinue: shouldContinue,
        deviceKey: deviceKey,
        deviceName: deviceName,
      );
    } on PhoneInvitationContinuationRequired catch (error) {
      invitationContinuation = error;
      state = const PhoneLoginState(PhoneLoginStatus.failed,
          message: '验证码已通过，请补填邀请码后继续注册');
      notifyListeners();
      return false;
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
          message: error is BusinessApiException && error.statusCode == 429
              ? '登录请求较频繁，请稍后重试'
              : _messageFor(error, fallback: '账号或验证码错误'),
          loginRetryAfterSeconds:
              error is BusinessApiException && error.statusCode == 429
                  ? (error.retryAfterSeconds ?? 60).clamp(1, 86400)
                  : null);
      notifyListeners();
      return false;
    }
    state = const PhoneLoginState(PhoneLoginStatus.succeeded);
    notifyListeners();
    return true;
  }

  void _refreshCooldown() {
    state = PhoneLoginState(state.status,
        message: state.message,
        resendAfterSeconds: _cooldown.remaining,
        loginRetryAfterSeconds: state.loginRetryAfterSeconds);
    notifyListeners();
  }

  void _startCooldownTicker() {
    if (_disposed) return;
    _cooldownTimer?.cancel();
    if (_cooldown.remaining == 0) return;
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _refreshCooldown();
      if (_cooldown.remaining == 0) timer.cancel();
    });
  }

  String _messageFor(Exception error, {required String fallback}) {
    switch (_errorCode(error)) {
      case 'INVITATION_REQUIRED':
      case 'INVITATION_INVALID':
      case 'INVITATION_EXPIRED':
      case 'INVITATION_EXHAUSTED':
        return '新用户需要填写有效邀请码';
      case 'PHONE_PROVISIONING_PENDING':
        return '账号仍在开通，请稍后重新登录；无需再次注册';
      case 'PHONE_REGISTRATION_INCOMPLETE':
        return '该手机号已开始注册，请完成原注册验证流程或联系客服';
      case 'LOGIN_TICKET_INVALID':
        return '登录凭据已失效，请重新登录';
      case 'TERMS_REQUIRED':
        return '请先阅读并同意用户协议和隐私政策';
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
