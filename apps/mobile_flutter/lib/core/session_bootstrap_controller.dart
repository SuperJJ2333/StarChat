import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import '../features/matrix/matrix_e2ee_client.dart';
import '../features/matrix/matrix_security_logger.dart';
import 'business_api_client.dart';
import 'cache/cache_repository.dart';

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
  SessionBootstrapController({
    required this.business,
    required this.matrix,
    MatrixSecurityLogger? securityLogger,
    this.remoteLogoutTimeout = const Duration(seconds: 5),
  }) : securityLogger =
            securityLogger ?? MatrixSecurityLogger.create(sink: (_) {});

  final BusinessSessionGateway business;
  final MatrixSessionGateway matrix;
  bool canShowCachedMessages = false;
  int _generation = 0;
  Future<void>? _bootstrapFlight;
  final MatrixSecurityLogger securityLogger;
  final Duration remoteLogoutTimeout;
  SessionBootstrapState state = const SessionBootstrapState(
    SessionBootstrapStatus.loading,
  );

  bool get _authenticated =>
      state.status == SessionBootstrapStatus.authenticated ||
      state.status == SessionBootstrapStatus.offlineAuthenticated;

  /// The completion belongs only to the business session that started work.
  Future<void> runAuthenticatedBackground({
    required Future<bool> Function() prepare,
    required Future<void> Function() complete,
  }) async {
    if (!_authenticated) return;
    final generation = _generation;
    if (!await prepare()) return;
    if (generation != _generation || !_authenticated) return;
    await complete();
  }

  Future<void> bootstrap() {
    final existing = _bootstrapFlight;
    if (existing != null) return existing;
    final flight = _bootstrap(++_generation);
    _bootstrapFlight = flight;
    return flight.whenComplete(() {
      if (identical(_bootstrapFlight, flight)) _bootstrapFlight = null;
    });
  }

  Future<void> _bootstrap(int generation) async {
    if (state.status != SessionBootstrapStatus.authenticated &&
        state.status != SessionBootstrapStatus.offlineAuthenticated) {
      canShowCachedMessages = false;
      _set(const SessionBootstrapState(SessionBootstrapStatus.loading));
    }
    try {
      final localIdentity = await business.currentMatrixUserId();
      if (generation != _generation) return;
      canShowCachedMessages = matrix.isLoggedIn &&
          localIdentity != null &&
          localIdentity == matrix.userId;
      notifyListeners();
      final businessResult = await business.restoreSession();
      if (generation != _generation) return;
      if (businessResult == BusinessSessionRestore.absent ||
          businessResult == BusinessSessionRestore.invalid) {
        // 业务会话失效（登出/令牌过期/瞬时刷新失败）时【不得】清除本地
        // 加密数据库：同账号重新登录后必须仍能解密历史消息。账号隔离
        // 由登录流程的身份校验保证（不同账号登录时才重置本地库）。
        _set(
          const SessionBootstrapState(SessionBootstrapStatus.unauthenticated),
        );
        final suspended = await _bestEffortMatrixSuspend();
        if (generation != _generation) return;
        if (!suspended) await _clearLocalBusinessSession();
        if (generation != _generation) return;
        if (!suspended) {
          _set(
            const SessionBootstrapState(
              SessionBootstrapStatus.unauthenticated,
              message: _suspendFailureMessage,
            ),
          );
        }
        return;
      }
      if (!matrix.isLoggedIn) {
        _set(
          const SessionBootstrapState(SessionBootstrapStatus.unauthenticated),
        );
        await _clearLocalBusinessSession();
        if (generation != _generation) return;
        final suspended = await _bestEffortMatrixSuspend();
        if (generation != _generation) return;
        if (!suspended) {
          _set(
            const SessionBootstrapState(
              SessionBootstrapStatus.unauthenticated,
              message: _suspendFailureMessage,
            ),
          );
        }
        return;
      }
      final expectedMatrixUser = await business.currentMatrixUserId();
      if (generation != _generation) return;
      if (expectedMatrixUser == null || expectedMatrixUser != matrix.userId) {
        _set(
          const SessionBootstrapState(
            SessionBootstrapStatus.fatalError,
            message: '本地登录身份不一致，请联系技术支持',
          ),
        );
        return;
      }
      // Both identities and the business session are verified. Matrix history
      // is already restored from disk; network sync must not block Messages.
      _set(
        SessionBootstrapState(
          businessResult == BusinessSessionRestore.offline
              ? SessionBootstrapStatus.offlineAuthenticated
              : SessionBootstrapStatus.authenticated,
        ),
      );
      if (generation != _generation || !_authenticated) return;
      try {
        await matrix.sync();
        if (generation != _generation) return;
      } on MatrixException catch (error) {
        if (generation != _generation) return;
        if (error.errcode == 'M_UNKNOWN_TOKEN' ||
            error.errcode == 'M_FORBIDDEN') {
          _set(
            const SessionBootstrapState(
              SessionBootstrapStatus.unauthenticated,
              message: '登录状态已失效，请重新登录',
            ),
          );
          await _clearLocalBusinessSession();
          if (generation != _generation) return;
          final suspended = await _bestEffortMatrixSuspend();
          if (generation != _generation) return;
          if (!suspended) {
            _set(
              const SessionBootstrapState(
                SessionBootstrapStatus.unauthenticated,
                message: _suspendFailureMessage,
              ),
            );
          }
          return;
        }
        rethrow;
      } on SocketException {
        if (generation != _generation) return;
        _set(
          const SessionBootstrapState(
            SessionBootstrapStatus.offlineAuthenticated,
          ),
        );
        return;
      } on TimeoutException {
        if (generation != _generation) return;
        _set(
          const SessionBootstrapState(
            SessionBootstrapStatus.offlineAuthenticated,
          ),
        );
        return;
      } on http.ClientException {
        if (generation != _generation) return;
        _set(
          const SessionBootstrapState(
            SessionBootstrapStatus.offlineAuthenticated,
          ),
        );
        return;
      }
      _set(
        SessionBootstrapState(
          businessResult == BusinessSessionRestore.offline
              ? SessionBootstrapStatus.offlineAuthenticated
              : SessionBootstrapStatus.authenticated,
        ),
      );
    } on SocketException {
      if (generation != _generation) return;
      _offlineIfPossible();
    } on TimeoutException {
      if (generation != _generation) return;
      _offlineIfPossible();
    } on http.ClientException {
      if (generation != _generation) return;
      _offlineIfPossible();
    } catch (_) {
      if (generation != _generation) return;
      _set(
        const SessionBootstrapState(
          SessionBootstrapStatus.fatalError,
          message: '无法恢复本地登录状态',
        ),
      );
    }
  }

  Future<void> logout() async {
    _generation++;
    _bootstrapFlight = null;
    canShowCachedMessages = false;
    _set(const SessionBootstrapState(SessionBootstrapStatus.unauthenticated));
    await _clearAccountMomentsCache();
    await _clearLocalBusinessSession();
    final suspended = await _bestEffortMatrixSuspend();
    if (!suspended) {
      _set(
        const SessionBootstrapState(
          SessionBootstrapStatus.unauthenticated,
          message: _suspendFailureMessage,
        ),
      );
    }
  }

  Future<void> _clearAccountMomentsCache() async {
    try {
      // 与 MomentsPage 同一命名空间（matrix:<userId>）：登出清当前账号。
      final matrixUserId = await business.currentMatrixUserId();
      if (matrixUserId == null || matrixUserId.isEmpty) return;
      final repository = await CacheRepository.instance();
      await repository.momentsFor('matrix:$matrixUserId').clear();
    } catch (_) {
      // 缓存清理尽力而为，不阻断登出。
    }
  }

  void _offlineIfPossible() {
    _set(
      SessionBootstrapState(
        canShowCachedMessages && matrix.isLoggedIn
            ? SessionBootstrapStatus.offlineAuthenticated
            : SessionBootstrapStatus.unauthenticated,
      ),
    );
  }

  Future<void> _clearLocalBusinessSession() async {
    try {
      final revocation = await business.clearLocalSession();
      if (revocation != null) {
        unawaited(_revokeBusinessSession(revocation));
      }
    } catch (_) {}
  }

  Future<void> _revokeBusinessSession(
    BusinessSessionRevocation revocation,
  ) async {
    try {
      await revocation.revoke().timeout(remoteLogoutTimeout);
    } catch (_) {}
  }

  Future<bool> _bestEffortMatrixSuspend() async {
    try {
      await matrix.suspend();
      return true;
    } catch (_) {
      securityLogger.record(
        stage: MatrixSecurityStage.lifecycle,
        outcome: MatrixSecurityOutcome.failure,
        eventCode: MatrixSecurityCode.lifecycleSuspendFailed,
      );
      return false;
    }
  }

  static const _suspendFailureMessage = '聊天会话暂停失败，请重新打开应用后重试';

  void _set(SessionBootstrapState next) {
    if (next.status == SessionBootstrapStatus.unauthenticated ||
        next.status == SessionBootstrapStatus.fatalError) {
      canShowCachedMessages = false;
    }
    state = next;
    notifyListeners();
  }
}
