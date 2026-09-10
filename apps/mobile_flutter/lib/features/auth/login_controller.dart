import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../core/business_api_error.dart';
import '../../core/business_auth_contracts.dart';

typedef LoginOperation = Future<void> Function(
    String username, String password);

enum MatrixIdentityDecision {
  firstLogin,
  reuse,
  reauthenticate,
  switchRequired,
}

final class MatrixAccountSwitchRequired implements Exception {
  const MatrixAccountSwitchRequired({
    required this.fromMxid,
    required this.toMxid,
  });

  final String fromMxid;
  final String toMxid;

  @override
  String toString() => 'MATRIX_ACCOUNT_SWITCH_REQUIRED';
}

abstract interface class MatrixTokenLoginGateway {
  bool get isLoggedIn;
  bool get credentialsInvalid;
  String? get userId;
  String? get deviceId;
  Future<void> loginWithToken({
    required String loginToken,
    required Uri homeserver,
    String? deviceId,
  });
  Future<void> sync();
  Future<void> suspend();
  Future<void> clearLocalChatData();
}

abstract interface class MatrixAccountSelectionGateway {
  Future<void> selectAccount(String matrixUserId, Uri homeserver);
}

final class DualDomainLoginService {
  DualDomainLoginService({
    required this.business,
    required this.matrix,
    required this.deviceKey,
    this.retainedHomeserver,
    this.completeMatrixSession,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final DualDomainBusinessGateway business;
  final MatrixTokenLoginGateway matrix;
  final String Function() deviceKey;
  final Uri? retainedHomeserver;
  final Future<void> Function()? completeMatrixSession;
  String get _retainedHomeserver =>
      retainedHomeserver?.toString() ??
      (throw StateError('Account homeserver is not configured'));
  final DateTime Function() now;
  MatrixAccountSwitchRequired? _pendingAccountSwitch;
  MatrixLoginGrant? _pendingGrant;
  DateTime? _pendingGrantExpiresAt;
  bool _operationRunning = false;
  DateTime? _retryAt;
  String _stage = 'business_login';

  Future<void> _run(Future<void> Function() operation) async {
    if (_operationRunning) {
      throw const BusinessApiException(
          statusCode: 409, code: 'LOGIN_IN_PROGRESS', message: '登录正在进行，请稍候');
    }
    if (_retryAt != null && _retryAt!.isAfter(now())) {
      final seconds = (_retryAt!.difference(now()).inMilliseconds / 1000)
          .ceil()
          .clamp(1, 86400);
      throw BusinessApiException(
          statusCode: 429,
          code: 'MATRIX_LOGIN_RATE_LIMITED',
          message: '聊天登录请求较频繁，请等待 $seconds 秒后重试',
          retryAfterSeconds: seconds);
    }
    _operationRunning = true;
    try {
      await operation();
    } on BusinessApiException catch (error) {
      if (error.statusCode == 429) {
        _retryAt = now().add(Duration(seconds: error.retryAfterSeconds ?? 60));
      }
      rethrow;
    } finally {
      _operationRunning = false;
    }
  }

  void _forgetPending() {
    _pendingAccountSwitch = null;
    _pendingGrant = null;
    _pendingGrantExpiresAt = null;
  }

  Future<void> cancelAccountSwitch() async {
    if (_operationRunning) {
      throw const BusinessApiException(
          statusCode: 409, code: 'LOGIN_IN_PROGRESS', message: '登录正在进行，请稍候');
    }
    _operationRunning = true;
    try {
      _forgetPending();
      await business.logoutBusiness();
    } finally {
      _operationRunning = false;
    }
  }

  Future<MatrixLoginGrant> _issueGrant() async {
    _stage = 'matrix_grant';
    final start = now();
    try {
      final grant = await business.issueMatrixLoginToken();
      final expiresAt = start
          .add(Duration(seconds: grant.expiresIn.clamp(0, 60)))
          .subtract(const Duration(seconds: 5));
      if (!now().isBefore(expiresAt)) {
        throw const BusinessApiException(
            statusCode: 408,
            code: 'MATRIX_LOGIN_GRANT_EXPIRED',
            message: '聊天登录凭据已过期，请重试');
      }
      _pendingGrant = grant;
      _pendingGrantExpiresAt = expiresAt;
      return grant;
    } on BusinessApiException {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
          LoginStageException(_stage,
              network: error is SocketException ||
                  error is TimeoutException ||
                  error is http.ClientException),
          stackTrace);
    }
  }

  Future<void> _compensate({bool revokeBusiness = true}) async {
    try {
      if (revokeBusiness) await business.logoutBusiness();
    } catch (_) {/* Preserve original failure. */}
    try {
      await matrix.suspend();
    } catch (_) {/* Preserve original failure. */}
  }

  Future<void> login(String username, String password) =>
      _run(() => _login(username, password));

  Future<void> _login(String username, String password) async {
    _forgetPending();
    _stage = 'business_login';
    await business.loginBusiness(
      username: username,
      password: password,
      deviceKey: deviceKey(),
      deviceName: '畅聊移动端',
    );
    try {
      if (matrix is MatrixAccountSelectionGateway) {
        await _loginRetained();
        return;
      }
      _stage = 'local_identity';
      final boundMatrixUserId = await business.currentMatrixUserId();
      if (matrix.isLoggedIn && !matrix.credentialsInvalid) {
        if (boundMatrixUserId != null && matrix.userId == boundMatrixUserId) {
          _stage = 'matrix_sync';
          await matrix.sync();
          _stage = 'identity_binding';
          await business.bindMatrixUserId(boundMatrixUserId);
          return;
        }
        if (boundMatrixUserId != null && matrix.userId != boundMatrixUserId) {
          throw _requireAccountSwitch(
            fromMxid: matrix.userId!,
            toMxid: boundMatrixUserId,
          );
        }
      }
      final grant = await _issueGrant();
      if (matrix.isLoggedIn && matrix.userId != grant.matrixUserId) {
        throw _requireAccountSwitch(
          fromMxid: matrix.userId!,
          toMxid: grant.matrixUserId,
        );
      }
      if (!matrix.isLoggedIn || matrix.credentialsInvalid) {
        _pendingGrant = null;
        _pendingGrantExpiresAt = null;
        _stage = 'matrix_login';
        await matrix.loginWithToken(
          loginToken: grant.loginToken,
          homeserver: Uri.parse(grant.homeserver),
          deviceId: matrix.deviceId,
        );
      }
      if (matrix.userId != grant.matrixUserId) {
        throw StateError('Matrix login returned an unexpected identity');
      }
      _stage = 'matrix_sync';
      await matrix.sync();
      _stage = 'identity_binding';
      await business.bindMatrixUserId(grant.matrixUserId);
      _forgetPending();
    } on MatrixAccountSwitchRequired {
      rethrow;
    } catch (error, stackTrace) {
      _forgetPending();
      final network = (error is LoginStageException && error.network) ||
          error is SocketException ||
          error is TimeoutException ||
          error is http.ClientException;
      final pendingCompletion = error is BusinessApiException &&
          error.code == 'MATRIX_SESSION_REVOKE_PENDING';
      if (!network && !pendingCompletion) await _compensate();
      if (error is BusinessApiException || error is LoginStageException) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      // Only fixed stage names are exposed. Never stringify the original error.
      Error.throwWithStackTrace(
          LoginStageException(_stage, network: network), stackTrace);
    }
  }

  Future<void> _loginRetained() async {
    final selector = matrix as MatrixAccountSelectionGateway;
    _stage = 'local_identity';
    var target = await business.currentMatrixUserId();
    MatrixLoginGrant? grant;
    if (target == null) {
      grant = await _issueGrant();
      target = grant.matrixUserId;
    }
    if (matrix.userId != target) {
      _stage = 'account_storage';
      await selector.selectAccount(
          target, Uri.parse(grant?.homeserver ?? _retainedHomeserver));
    }
    if (!matrix.isLoggedIn || matrix.credentialsInvalid) {
      if (grant == null ||
          _pendingGrantExpiresAt == null ||
          !now().isBefore(_pendingGrantExpiresAt!)) {
        grant = await _issueGrant();
      }
      if (grant.matrixUserId != target) {
        throw StateError('Matrix login target changed');
      }
      _pendingGrant = null;
      _pendingGrantExpiresAt = null;
      _stage = 'matrix_login';
      await matrix.loginWithToken(
          loginToken: grant.loginToken,
          homeserver: Uri.parse(grant.homeserver),
          deviceId: matrix.deviceId);
    }
    if (matrix.userId != target || matrix.deviceId == null) {
      throw StateError('Matrix login returned an unexpected identity');
    }
    _stage = 'identity_binding';
    await business.bindMatrixUserId(target);
    if (completeMatrixSession != null) {
      _stage = 'matrix_session';
      await completeMatrixSession!();
    }
    _stage = 'matrix_sync';
    await matrix.sync();
    _forgetPending();
  }

  Future<void> confirmAccountSwitchAndLogin() => _run(() async {
        final pending = _pendingAccountSwitch;
        if (pending == null) {
          throw StateError('No Matrix account switch is pending');
        }
        var grant = _pendingGrant;
        if (grant == null ||
            _pendingGrantExpiresAt == null ||
            !now().isBefore(_pendingGrantExpiresAt!)) {
          grant = await _issueGrant();
        }
        if (grant.matrixUserId != pending.toMxid) {
          _forgetPending();
          throw StateError('Matrix account switch target changed');
        }
        // This authorization belongs only to this attempt. Invalidate before any
        // destructive action or network submission; uncertain consumption is final.
        _forgetPending();
        try {
          _stage = 'switch_local_clear';
          if (matrix is! MatrixAccountSelectionGateway) {
            throw const BusinessApiException(
                statusCode: 409,
                code: 'ACCOUNT_STORAGE_UNAVAILABLE',
                message: '此客户端无法安全切换账号，请升级后重试');
          }
          await (matrix as MatrixAccountSelectionGateway)
              .selectAccount(pending.toMxid, Uri.parse(grant.homeserver));
          _stage = 'matrix_login';
          await matrix.loginWithToken(
              loginToken: grant.loginToken,
              homeserver: Uri.parse(grant.homeserver));
          if (matrix.userId != pending.toMxid || matrix.deviceId == null) {
            throw StateError('Matrix login returned an unexpected identity');
          }
          _stage = 'matrix_sync';
          await matrix.sync();
          _stage = 'identity_binding';
          await business.bindMatrixUserId(pending.toMxid);
        } catch (error, stackTrace) {
          final network = error is SocketException ||
              error is TimeoutException ||
              error is http.ClientException;
          await _compensate(revokeBusiness: !network);
          if (error is BusinessApiException) {
            Error.throwWithStackTrace(error, stackTrace);
          }
          Error.throwWithStackTrace(
              LoginStageException(_stage, network: network), stackTrace);
        }
      });

  MatrixAccountSwitchRequired _requireAccountSwitch({
    required String fromMxid,
    required String toMxid,
  }) {
    final required = MatrixAccountSwitchRequired(
      fromMxid: fromMxid,
      toMxid: toMxid,
    );
    _pendingAccountSwitch = required;
    return required;
  }
}

final class LoginStageException implements Exception {
  const LoginStageException(this.stage, {this.network = false});
  final String stage;
  final bool network;
  String get diagnosticCode =>
      const {
        'local_identity': 'L01',
        'matrix_grant': 'L02',
        'switch_local_clear': 'L03',
        'matrix_login': 'L04',
        'matrix_sync': 'L05',
        'identity_binding': 'L06',
        'account_storage': 'L07',
        'matrix_session': 'L08',
      }[stage] ??
      'L00';
  String get message => network
      ? '聊天登录连接中断，请重试（$diagnosticCode）'
      : '聊天登录未完成，请重试（$diagnosticCode）';
}

enum LoginStatus { idle, loading, succeeded, failed }

final class LoginAuthenticationException implements Exception {
  const LoginAuthenticationException();
}

final class LoginState {
  const LoginState(this.status, {this.message});
  final LoginStatus status;
  final String? message;
}

final class LoginController extends ChangeNotifier {
  LoginController({
    required this.operation,
    Future<void> Function(Duration)? delay,
  }) : delay = delay ?? Future.delayed;
  factory LoginController.dualDomain({
    required DualDomainBusinessGateway business,
    required MatrixTokenLoginGateway matrix,
    required String Function() deviceKey,
    Future<void> Function(Duration)? delay,
  }) {
    final service = DualDomainLoginService(
      business: business,
      matrix: matrix,
      deviceKey: deviceKey,
    );
    return LoginController(operation: service.login, delay: delay);
  }
  final LoginOperation operation;
  final Future<void> Function(Duration) delay;
  LoginState state = const LoginState(LoginStatus.idle);
  String? _username, _password;
  Future<bool> submit(String username, String password) async {
    if (state.status == LoginStatus.loading) return false;
    _username = username;
    _password = password;
    state = const LoginState(LoginStatus.loading);
    notifyListeners();
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await operation(username, password);
        state = const LoginState(LoginStatus.succeeded);
        notifyListeners();
        return true;
      } on LoginAuthenticationException {
        state = const LoginState(LoginStatus.failed, message: '账号或密码错误');
        notifyListeners();
        return false;
      } on BusinessApiException catch (error) {
        state = LoginState(
          LoginStatus.failed,
          message: error.statusCode == 401 ? '账号或密码错误' : error.message,
        );
        notifyListeners();
        return false;
      } on SocketException catch (_) {
        if (attempt < 2) {
          await delay(Duration(milliseconds: 250 * (1 << attempt)));
          continue;
        }
        state = const LoginState(LoginStatus.failed, message: '网络连接不稳定，请重试');
        notifyListeners();
        return false;
      } on TimeoutException catch (_) {
        if (attempt < 2) {
          await delay(Duration(milliseconds: 250 * (1 << attempt)));
          continue;
        }
        state = const LoginState(LoginStatus.failed, message: '网络连接不稳定，请重试');
        notifyListeners();
        return false;
      } on http.ClientException catch (_) {
        if (attempt < 2) {
          await delay(Duration(milliseconds: 250 * (1 << attempt)));
          continue;
        }
        state = const LoginState(LoginStatus.failed, message: '网络连接不稳定，请重试');
        notifyListeners();
        return false;
      } on LoginStageException catch (error) {
        state = LoginState(LoginStatus.failed, message: error.message);
        notifyListeners();
        return false;
      } on MatrixAccountSwitchRequired {
        rethrow;
      } catch (_) {
        state = const LoginState(LoginStatus.failed, message: '服务暂时不可用，请稍后重试');
        notifyListeners();
        return false;
      }
    }
    return false;
  }

  Future<bool> retryNow() => submit(_username ?? '', _password ?? '');
}
