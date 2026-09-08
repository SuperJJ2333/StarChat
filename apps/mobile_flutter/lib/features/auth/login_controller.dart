import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../core/business_api_error.dart';
import '../../core/business_auth_contracts.dart';

typedef LoginOperation =
    Future<void> Function(String username, String password);

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

final class DualDomainLoginService {
  DualDomainLoginService({
    required this.business,
    required this.matrix,
    required this.deviceKey,
  });
  final DualDomainBusinessGateway business;
  final MatrixTokenLoginGateway matrix;
  final String Function() deviceKey;
  MatrixAccountSwitchRequired? _pendingAccountSwitch;

  Future<void> login(String username, String password) async {
    await business.loginBusiness(
      username: username,
      password: password,
      deviceKey: deviceKey(),
      deviceName: '畅聊移动端',
    );
    try {
      final boundMatrixUserId = await business.currentMatrixUserId();
      if (matrix.isLoggedIn && !matrix.credentialsInvalid) {
        if (boundMatrixUserId != null && matrix.userId == boundMatrixUserId) {
          await matrix.sync();
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
      final grant = await business.issueMatrixLoginToken();
      if (matrix.isLoggedIn && matrix.userId != grant.matrixUserId) {
        throw _requireAccountSwitch(
          fromMxid: matrix.userId!,
          toMxid: grant.matrixUserId,
        );
      }
      if (!matrix.isLoggedIn || matrix.credentialsInvalid) {
        await matrix.loginWithToken(
          loginToken: grant.loginToken,
          homeserver: Uri.parse(grant.homeserver),
          deviceId: matrix.deviceId,
        );
      }
      if (matrix.userId != grant.matrixUserId) {
        throw StateError('Matrix login returned an unexpected identity');
      }
      await matrix.sync();
      await business.bindMatrixUserId(grant.matrixUserId);
    } on MatrixAccountSwitchRequired {
      rethrow;
    } on SocketException catch (error, stackTrace) {
      // 网络类失败：保留本地加密库与会话，重试登录即可。
      Error.throwWithStackTrace(error, stackTrace);
    } on TimeoutException catch (error, stackTrace) {
      Error.throwWithStackTrace(error, stackTrace);
    } on http.ClientException catch (error, stackTrace) {
      Error.throwWithStackTrace(error, stackTrace);
    } catch (error, stackTrace) {
      // Close the authentication gate while retaining the local encrypted store.
      await business.logoutBusiness();
      await _cleanupMatrix();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Completes only the destructive Matrix part of a switch the user has
  /// explicitly confirmed. A second grant is required because login tokens
  /// are short lived and an account may have changed while the prompt was up.
  Future<void> confirmAccountSwitchAndLogin() async {
    final pending = _pendingAccountSwitch;
    if (pending == null) {
      throw StateError('No Matrix account switch is pending');
    }

    // Validate the fresh grant before mutating any of the old local data.
    final grant = await business.issueMatrixLoginToken();
    if (grant.matrixUserId != pending.toMxid) {
      throw StateError('Matrix account switch target changed');
    }

    await matrix.clearLocalChatData();
    try {
      await matrix.loginWithToken(
        loginToken: grant.loginToken,
        homeserver: Uri.parse(grant.homeserver),
      );
      if (matrix.userId != pending.toMxid || matrix.deviceId == null) {
        throw StateError('Matrix login returned an unexpected identity');
      }
      await matrix.sync();
      await business.bindMatrixUserId(pending.toMxid);
      _pendingAccountSwitch = null;
    } catch (error, stackTrace) {
      await _cleanupMatrix();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

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

  Future<void> _cleanupMatrix() async {
    await matrix.suspend();
  }
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
