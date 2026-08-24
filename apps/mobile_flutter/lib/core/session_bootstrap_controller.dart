import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import '../features/matrix/matrix_e2ee_client.dart';
import 'business_api_client.dart';

enum SessionBootstrapStatus {
  loading,
  authenticated,
  offlineAuthenticated,
  unauthenticated,
  fatalError,
}

final class SessionBootstrapState {
  const SessionBootstrapState(this.status, {this.message});
  final SessionBootstrapStatus status;
  final String? message;
}

final class SessionBootstrapController extends ChangeNotifier {
  SessionBootstrapController({required this.business, required this.matrix});

  final BusinessSessionGateway business;
  final MatrixSessionGateway matrix;
  SessionBootstrapState state =
      const SessionBootstrapState(SessionBootstrapStatus.loading);

  Future<void> bootstrap() async {
    _set(const SessionBootstrapState(SessionBootstrapStatus.loading));
    try {
      final businessResult = await business.restoreSession();
      if (businessResult == BusinessSessionRestore.absent ||
          businessResult == BusinessSessionRestore.invalid) {
        if (matrix.isLoggedIn) await _bestEffortMatrixReset();
        _set(const SessionBootstrapState(
            SessionBootstrapStatus.unauthenticated));
        return;
      }
      if (!matrix.isLoggedIn) {
        await _bestEffortBusinessLogout();
        _set(const SessionBootstrapState(
            SessionBootstrapStatus.unauthenticated));
        return;
      }
      final expectedMatrixUser = await business.currentMatrixUserId();
      if (expectedMatrixUser == null || expectedMatrixUser != matrix.userId) {
        _set(const SessionBootstrapState(
          SessionBootstrapStatus.fatalError,
          message: '本地登录身份不一致，请联系技术支持',
        ));
        return;
      }
      try {
        await matrix.sync();
      } on MatrixException catch (error) {
        if (error.errcode == 'M_UNKNOWN_TOKEN' ||
            error.errcode == 'M_FORBIDDEN') {
          await _bestEffortBusinessLogout();
          await _bestEffortMatrixReset();
          _set(const SessionBootstrapState(
            SessionBootstrapStatus.unauthenticated,
            message: '登录状态已失效，请重新登录',
          ));
          return;
        }
        rethrow;
      } on SocketException {
        _set(const SessionBootstrapState(
            SessionBootstrapStatus.offlineAuthenticated));
        return;
      } on TimeoutException {
        _set(const SessionBootstrapState(
            SessionBootstrapStatus.offlineAuthenticated));
        return;
      } on http.ClientException {
        _set(const SessionBootstrapState(
            SessionBootstrapStatus.offlineAuthenticated));
        return;
      }
      _set(SessionBootstrapState(
        businessResult == BusinessSessionRestore.offline
            ? SessionBootstrapStatus.offlineAuthenticated
            : SessionBootstrapStatus.authenticated,
      ));
    } on SocketException {
      _offlineIfPossible();
    } on TimeoutException {
      _offlineIfPossible();
    } on http.ClientException {
      _offlineIfPossible();
    } catch (_) {
      _set(const SessionBootstrapState(
        SessionBootstrapStatus.fatalError,
        message: '无法恢复本地登录状态',
      ));
    }
  }

  Future<void> logout() async {
    await _bestEffortBusinessLogout();
    await _bestEffortMatrixSuspend();
    _set(const SessionBootstrapState(SessionBootstrapStatus.unauthenticated));
  }

  void _offlineIfPossible() {
    _set(SessionBootstrapState(
      matrix.isLoggedIn
          ? SessionBootstrapStatus.offlineAuthenticated
          : SessionBootstrapStatus.unauthenticated,
    ));
  }

  Future<void> _bestEffortBusinessLogout() async {
    try {
      await business.logout();
    } catch (_) {}
  }

  Future<void> _bestEffortMatrixSuspend() async {
    try {
      await matrix.suspend();
    } catch (_) {}
  }

  Future<void> _bestEffortMatrixReset() async {
    try {
      await matrix.resetLocalStore();
    } catch (_) {}
  }

  void _set(SessionBootstrapState next) {
    state = next;
    notifyListeners();
  }
}
