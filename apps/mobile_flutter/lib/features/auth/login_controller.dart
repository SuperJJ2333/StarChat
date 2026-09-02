import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../core/business_api_client.dart';

typedef LoginOperation = Future<void> Function(
    String username, String password);

final class MatrixLoginGrant {
  const MatrixLoginGrant(
      {required this.loginToken,
      required this.homeserver,
      required this.expiresIn,
      required this.matrixUserId});
  final String loginToken;
  final String homeserver;
  final int expiresIn;
  final String matrixUserId;
}

abstract interface class DualDomainBusinessGateway {
  Future<void> loginBusiness(
      {required String username,
      required String password,
      required String deviceKey,
      required String deviceName});
  Future<MatrixLoginGrant> issueMatrixLoginToken();
  Future<void> bindMatrixUserId(String matrixUserId);
  Future<void> logoutBusiness();
}

abstract interface class MatrixTokenLoginGateway {
  bool get isLoggedIn;
  String? get userId;
  Future<void> loginWithToken(
      {required String loginToken, required Uri homeserver});
  Future<void> sync();
  Future<void> logout();
  Future<void> resetLocalStore();
}

final class DualDomainLoginService {
  const DualDomainLoginService(
      {required this.business, required this.matrix, required this.deviceKey});
  final DualDomainBusinessGateway business;
  final MatrixTokenLoginGateway matrix;
  final String Function() deviceKey;
  Future<void> login(String username, String password) async {
    await business.loginBusiness(
      username: username,
      password: password,
      deviceKey: deviceKey(),
      deviceName: '畅聊移动端',
    );
    try {
      final grant = await business.issueMatrixLoginToken();
      if (matrix.isLoggedIn && matrix.userId != grant.matrixUserId) {
        await matrix.resetLocalStore();
      }
      if (!matrix.isLoggedIn) {
        await matrix.loginWithToken(
          loginToken: grant.loginToken,
          homeserver: Uri.parse(grant.homeserver),
        );
      }
      if (matrix.userId != grant.matrixUserId) {
        throw StateError('Matrix login returned an unexpected identity');
      }
      await matrix.sync();
      await business.bindMatrixUserId(grant.matrixUserId);
    } on SocketException catch (error, stackTrace) {
      // 网络类失败：保留本地加密库与会话，重试登录即可。
      Error.throwWithStackTrace(error, stackTrace);
    } on TimeoutException catch (error, stackTrace) {
      Error.throwWithStackTrace(error, stackTrace);
    } on http.ClientException catch (error, stackTrace) {
      Error.throwWithStackTrace(error, stackTrace);
    } catch (error, stackTrace) {
      // 账号隔离仍然成立：若之后以其他账号登录，身份校验会重置本地库。
      Error.throwWithStackTrace(error, stackTrace);
    }
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
  LoginController(
      {required this.operation, Future<void> Function(Duration)? delay})
      : delay = delay ?? Future.delayed;
  factory LoginController.dualDomain(
      {required DualDomainBusinessGateway business,
      required MatrixTokenLoginGateway matrix,
      required String Function() deviceKey,
      Future<void> Function(Duration)? delay}) {
    final service = DualDomainLoginService(
        business: business, matrix: matrix, deviceKey: deviceKey);
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
        state = LoginState(LoginStatus.failed,
            message: error.statusCode == 401 ? '账号或密码错误' : error.message);
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
