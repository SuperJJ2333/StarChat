import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/business_api_client.dart';

final class RegistrationReceipt {
  const RegistrationReceipt({required this.registrationSession, required this.status, required this.resendAfterSeconds});
  final String registrationSession;
  final String status;
  final int resendAfterSeconds;
}

final class RegistrationStatusReceipt {
  const RegistrationStatusReceipt({required this.status, required this.resendAfterSeconds});
  final String status;
  final int resendAfterSeconds;
}

abstract interface class RegistrationGateway {
  Future<bool> validateInvitation(String invitationCode);
  Future<RegistrationReceipt> register({required String username, required String email, required String password, required String invitationCode});
  Future<void> verifyEmail({required String registrationSession, String? code, String? token});
  Future<int> resendVerification(String registrationSession);
  Future<RegistrationStatusReceipt> registrationStatus(String registrationSession);
}

enum RegistrationFlowStatus { idle, submitting, awaitingVerification, provisioning, completed, failed }

final class RegistrationState {
  const RegistrationState(this.status, {this.registrationSession, this.resendAfterSeconds = 0, this.message, this.fieldErrors = const {}});
  final RegistrationFlowStatus status;
  final String? registrationSession;
  final int resendAfterSeconds;
  final String? message;
  final Map<String, String> fieldErrors;
}

final class RegistrationController extends ChangeNotifier {
  RegistrationController({required this.gateway, Future<void> Function(Duration)? delay}) : delay = delay ?? Future.delayed;
  final RegistrationGateway gateway;
  final Future<void> Function(Duration) delay;
  RegistrationState state = const RegistrationState(RegistrationFlowStatus.idle);

  Future<bool> register({required String username, required String email, required String password, required String invitationCode}) async {
    _set(const RegistrationState(RegistrationFlowStatus.submitting));
    try {
      if (!await _retryNetwork(() => gateway.validateInvitation(invitationCode))) {
        _set(const RegistrationState(RegistrationFlowStatus.failed, fieldErrors: {'invitation_code': '邀请码无效或已失效'}));
        return false;
      }
      final receipt = await _retryNetwork(() => gateway.register(username: username, email: email, password: password, invitationCode: invitationCode));
      _set(RegistrationState(RegistrationFlowStatus.awaitingVerification, registrationSession: receipt.registrationSession, resendAfterSeconds: receipt.resendAfterSeconds));
      return true;
    } on BusinessApiException catch (error) {
      _set(RegistrationState(RegistrationFlowStatus.failed, message: error.message, fieldErrors: _fieldErrors(error.code)));
      return false;
    } on SocketException catch (_) {
      _networkFailure(); return false;
    } on TimeoutException catch (_) {
      _networkFailure(); return false;
    } on http.ClientException catch (_) {
      _networkFailure(); return false;
    }
  }

  Future<void> verifyCode(String code) => _verify(code: code);
  Future<void> verifyLinkToken(String token) => _verify(token: token);

  Future<void> _verify({String? code, String? token}) async {
    final session = state.registrationSession;
    if (session == null) throw StateError('registration session is missing');
    await _retryNetwork(() => gateway.verifyEmail(registrationSession: session, code: code, token: token));
    _set(RegistrationState(RegistrationFlowStatus.provisioning, registrationSession: session));
  }

  Future<bool> pollUntilActive({int maxAttempts = 30}) async {
    final session = state.registrationSession;
    if (session == null) throw StateError('registration session is missing');
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final receipt = await _retryNetwork(() => gateway.registrationStatus(session));
      if (receipt.status == 'ACTIVE') {
        _set(RegistrationState(RegistrationFlowStatus.completed, registrationSession: session));
        return true;
      }
      _set(RegistrationState(RegistrationFlowStatus.provisioning, registrationSession: session, resendAfterSeconds: receipt.resendAfterSeconds));
      if (attempt + 1 < maxAttempts) await delay(const Duration(seconds: 1));
    }
    return false;
  }

  Future<void> resend() async {
    final session = state.registrationSession;
    if (session == null || state.resendAfterSeconds > 0) return;
    final seconds = await _retryNetwork(() => gateway.resendVerification(session));
    _set(RegistrationState(RegistrationFlowStatus.awaitingVerification, registrationSession: session, resendAfterSeconds: seconds));
  }

  void tickSecond() {
    if (state.resendAfterSeconds <= 0) return;
    _set(RegistrationState(state.status, registrationSession: state.registrationSession, resendAfterSeconds: state.resendAfterSeconds - 1, message: state.message, fieldErrors: state.fieldErrors));
  }

  Future<T> _retryNetwork<T>(Future<T> Function() operation) async {
    for (var attempt = 0; ; attempt++) {
      try { return await operation(); }
      on SocketException catch (_) { if (attempt >= 2) rethrow; }
      on TimeoutException catch (_) { if (attempt >= 2) rethrow; }
      on http.ClientException catch (_) { if (attempt >= 2) rethrow; }
      await delay(Duration(milliseconds: 250 * (1 << attempt)));
    }
  }

  static Map<String, String> _fieldErrors(String code) => switch (code) {
    'INVITATION_INVALID' || 'INVITATION_EXPIRED' || 'INVITATION_EXHAUSTED' => const {'invitation_code': '邀请码无效或已失效'},
    'USERNAME_TAKEN' => const {'username': '用户名已被使用'},
    'EMAIL_TAKEN' => const {'email': '邮箱已被使用'},
    'REGISTRATION_INVALID' => const {'form': '请检查注册信息'},
    'REGISTRATION_CONFLICT' => const {'username': '用户名或邮箱已被使用', 'email': '用户名或邮箱已被使用'},
    'EMAIL_VERIFICATION_CREDENTIAL_REQUIRED' => const {'code': '请输入验证码或打开验证链接'},
    'EMAIL_VERIFICATION_INVALID' => const {'code': '验证码或验证链接错误或已失效'},
    'EMAIL_VERIFICATION_CODE_INVALID' => const {'code': '验证码错误或已失效'},
    _ => const {},
  };

  void _networkFailure() => _set(const RegistrationState(RegistrationFlowStatus.failed, message: '网络连接不稳定，请重试'));
  void _set(RegistrationState next) { state = next; notifyListeners(); }
}
