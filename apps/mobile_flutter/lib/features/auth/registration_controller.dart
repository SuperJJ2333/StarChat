import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/business_api_client.dart';
import 'invitation_validation.dart';

final class RegistrationReceipt {
  const RegistrationReceipt(
      {required this.registrationSession,
      required this.status,
      required this.resendAfterSeconds});
  final String registrationSession;
  final String status;
  final int resendAfterSeconds;
}

final class RegistrationStatusReceipt {
  const RegistrationStatusReceipt(
      {required this.status, required this.resendAfterSeconds});
  final String status;
  final int resendAfterSeconds;
}

abstract interface class RegistrationGateway {
  /// 校验管理员邀请码：200 → 结果对象（READY/INVALID/EXPIRED/EXHAUSTED）；
  /// 网络/服务端故障抛异常，由调用方映射为可重试状态。
  Future<InvitationValidationResult> validateInvitation(String invitationCode);

  /// 公开校验好友推荐码（选填字段）：仅提示有效性，不阻断注册。
  Future<bool> validateReferralCode(String referralCode);
  Future<RegistrationReceipt> register(
      {required String username,
      String? nickname,
      required String email,
      required String password,
      required String invitationCode,
      String referralCode = ''});
  Future<void> verifyEmail(
      {required String registrationSession, String? code, String? token});
  Future<int> resendVerification(String registrationSession);
  Future<RegistrationStatusReceipt> registrationStatus(
      String registrationSession);
}

enum RegistrationFlowStatus {
  idle,
  submitting,
  awaitingVerification,
  provisioning,
  completed,
  failed
}

final class RegistrationState {
  const RegistrationState(this.status,
      {this.registrationSession,
      this.resendAfterSeconds = 0,
      this.message,
      this.fieldErrors = const {}});
  final RegistrationFlowStatus status;
  final String? registrationSession;
  final int resendAfterSeconds;
  final String? message;
  final Map<String, String> fieldErrors;
}

final class RegistrationDraft {
  const RegistrationDraft({
    this.nickname = '',
    this.username = '',
    this.password = '',
    this.passwordConfirmation = '',
    this.invitationCode = '',
    this.referralCode = '',
    this.email = '',
  });
  final String nickname;
  final String username;
  final String password;
  final String passwordConfirmation;
  final String invitationCode;

  /// 好友推荐码（选填）：填写且有效才建立邀请关系，无效不阻断注册。
  final String referralCode;
  final String email;
}

final class RegistrationController extends ChangeNotifier {
  RegistrationController(
      {required this.gateway, Future<void> Function(Duration)? delay})
      : delay = delay ?? Future.delayed;
  final RegistrationGateway gateway;
  final Future<void> Function(Duration) delay;
  Timer? _cooldownTimer;
  RegistrationState state =
      const RegistrationState(RegistrationFlowStatus.idle);
  RegistrationDraft draft = const RegistrationDraft();
  String? verificationCodeHint;

  void saveDraft({
    required String nickname,
    required String username,
    required String password,
    required String passwordConfirmation,
    required String invitationCode,
    required String email,
    String referralCode = '',
  }) {
    draft = RegistrationDraft(
      nickname: nickname,
      username: username,
      password: password,
      passwordConfirmation: passwordConfirmation,
      invitationCode: invitationCode,
      email: email,
      referralCode: referralCode,
    );
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    super.dispose();
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      tickSecond();
      if (state.resendAfterSeconds <= 0) _cooldownTimer?.cancel();
    });
  }

  void setVerificationCodeHint(String value) {
    verificationCodeHint = value.trim().isEmpty ? null : value.trim();
  }

  static Map<String, String> validateFields({
    required String username,
    String nickname = '',
    required String email,
    required String password,
    required String passwordConfirmation,
    required String invitationCode,
  }) {
    final errors = <String, String>{};
    final usernameClean = username.trim();
    final nicknameClean = nickname.trim();
    final emailClean = email.trim();
    final invitationClean = invitationCode.trim();
    if (nicknameClean.isEmpty || nicknameClean.length > 64) {
      errors['nickname'] = '用户名需填写 1-64 个字符';
    }
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_-]{2,63}$').hasMatch(usernameClean)) {
      errors['username'] = '畅聊号需为 3-64 位字母、数字、下划线或连字符，且以字母开头';
    }
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(emailClean)) {
      errors['email'] = '请输入有效的邮箱地址';
    }
    if (password.length < 12) {
      errors['password'] = '密码至少需要 12 位';
    }
    if (passwordConfirmation.isNotEmpty && password != passwordConfirmation) {
      errors['password_confirmation'] = '两次密码输入不一致';
    }
    if (invitationClean.isEmpty) {
      errors['invitation_code'] = '请输入邀请码';
    }
    return errors;
  }

  Future<bool> register(
      {required String username,
      String? nickname,
      required String email,
      required String password,
      String passwordConfirmation = '',
      required String invitationCode,
      String referralCode = ''}) async {
    final validation = validateFields(
      username: username,
      nickname: nickname ?? username,
      email: email,
      password: password,
      passwordConfirmation: passwordConfirmation,
      invitationCode: invitationCode,
    );
    if (validation.isNotEmpty) {
      _set(RegistrationState(RegistrationFlowStatus.failed,
          fieldErrors: validation));
      return false;
    }
    saveDraft(
      nickname: nickname ?? username,
      username: username,
      password: password,
      passwordConfirmation: passwordConfirmation,
      invitationCode: invitationCode,
      email: email,
      referralCode: referralCode,
    );
    _set(const RegistrationState(RegistrationFlowStatus.submitting));
    try {
      final invitationCheck = await _retryNetwork(
          () => gateway.validateInvitation(invitationCode));
      if (invitationCheck.state != InvitationValidationState.ready) {
        _set(RegistrationState(RegistrationFlowStatus.failed,
            fieldErrors: {'invitation_code': invitationCheck.message}));
        return false;
      }
      // 好友推荐码选填：填写时先校验，无效给明确提示（可清空/改正），
      // 避免静默丢失邀请关系；留空直接跳过。
      final referralClean = referralCode.trim();
      if (referralClean.isNotEmpty &&
          !await _retryNetwork(
              () => gateway.validateReferralCode(referralClean))) {
        _set(const RegistrationState(RegistrationFlowStatus.failed,
            fieldErrors: {'referral_code': '邀请码无效，请核对或留空'}));
        return false;
      }
      final receipt = await _retryNetwork(() => gateway.register(
          username: username,
          nickname: nickname,
          email: email,
          password: password,
          invitationCode: invitationCode,
          referralCode: referralClean));
      _set(RegistrationState(RegistrationFlowStatus.awaitingVerification,
          registrationSession: receipt.registrationSession,
          resendAfterSeconds: receipt.resendAfterSeconds));
      _startCooldown();
      return true;
    } on BusinessApiException catch (error) {
      _set(RegistrationState(RegistrationFlowStatus.failed,
          message: error.message,
          fieldErrors: error.fieldErrors.isNotEmpty
              ? error.fieldErrors
              : _fieldErrors(error.code)));
      return false;
    } on SocketException catch (_) {
      _networkFailure();
      return false;
    } on TimeoutException catch (_) {
      _networkFailure();
      return false;
    } on http.ClientException catch (_) {
      _networkFailure();
      return false;
    }
  }

  Future<void> verifyCode(String code) => _verify(code: code);
  Future<void> verifyLinkToken(String token) => _verify(token: token);

  void clearVerificationCodeError() {
    if (!state.fieldErrors.containsKey('code')) return;
    final fieldErrors = Map<String, String>.from(state.fieldErrors)
      ..remove('code');
    _set(RegistrationState(state.status,
        registrationSession: state.registrationSession,
        resendAfterSeconds: state.resendAfterSeconds,
        message: state.message,
        fieldErrors: fieldErrors));
  }

  Future<void> _verify({String? code, String? token}) async {
    final session = state.registrationSession;
    if (session == null) throw StateError('registration session is missing');
    try {
      await _retryNetwork(() => gateway.verifyEmail(
          registrationSession: session, code: code, token: token));
      _set(RegistrationState(RegistrationFlowStatus.provisioning,
          registrationSession: session));
    } on BusinessApiException catch (error) {
      final fieldErrors = error.fieldErrors.isNotEmpty
          ? error.fieldErrors
          : _fieldErrors(error.code);
      _set(RegistrationState(RegistrationFlowStatus.awaitingVerification,
          registrationSession: session,
          resendAfterSeconds: state.resendAfterSeconds,
          message: error.message,
          fieldErrors: fieldErrors));
    }
  }

  Future<bool> pollUntilActive({int maxAttempts = 30}) async {
    final session = state.registrationSession;
    if (session == null) throw StateError('registration session is missing');
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final receipt =
          await _retryNetwork(() => gateway.registrationStatus(session));
      if (receipt.status == 'ACTIVE') {
        _set(RegistrationState(RegistrationFlowStatus.completed,
            registrationSession: session));
        return true;
      }
      _set(RegistrationState(RegistrationFlowStatus.provisioning,
          registrationSession: session,
          resendAfterSeconds: receipt.resendAfterSeconds));
      if (attempt + 1 < maxAttempts) await delay(const Duration(seconds: 1));
    }
    return false;
  }

  Future<void> resend() async {
    final session = state.registrationSession;
    if (session == null || state.resendAfterSeconds > 0) return;
    final seconds =
        await _retryNetwork(() => gateway.resendVerification(session));
    _set(RegistrationState(RegistrationFlowStatus.awaitingVerification,
        registrationSession: session, resendAfterSeconds: seconds));
    _startCooldown();
  }

  void tickSecond() {
    if (state.resendAfterSeconds <= 0) return;
    _set(RegistrationState(state.status,
        registrationSession: state.registrationSession,
        resendAfterSeconds: state.resendAfterSeconds - 1,
        message: state.message,
        fieldErrors: state.fieldErrors));
  }

  Future<T> _retryNetwork<T>(Future<T> Function() operation) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await operation();
      } on SocketException catch (_) {
        if (attempt >= 2) rethrow;
      } on TimeoutException catch (_) {
        if (attempt >= 2) rethrow;
      } on http.ClientException catch (_) {
        if (attempt >= 2) rethrow;
      }
      await delay(Duration(milliseconds: 250 * (1 << attempt)));
    }
  }

  static Map<String, String> _fieldErrors(String code) => switch (code) {
        'INVITATION_INVALID' ||
        'INVITATION_EXPIRED' ||
        'INVITATION_EXHAUSTED' =>
          const {'invitation_code': '邀请码无效或已失效'},
        'USERNAME_TAKEN' => const {'username': '用户名已被使用'},
        'EMAIL_TAKEN' => const {'email': '邮箱已被使用'},
        'REGISTRATION_INVALID' => const {'form': '请检查注册信息'},
        'REGISTRATION_CONFLICT' => const {'email': '邮箱已被使用'},
        'EMAIL_VERIFICATION_CREDENTIAL_REQUIRED' => const {
            'code': '请输入验证码或打开验证链接'
          },
        'EMAIL_VERIFICATION_INVALID' => const {'code': '验证码错误，请重新输入'},
        'EMAIL_VERIFICATION_CODE_INVALID' => const {'code': '验证码错误，请重新输入'},
        _ => const {},
      };

  void _networkFailure() =>
      _set(const RegistrationState(RegistrationFlowStatus.failed,
          message: '网络连接不稳定，请重试'));
  void _set(RegistrationState next) {
    state = next;
    notifyListeners();
  }
}
