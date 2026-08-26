import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_bootstrap_controller.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:matrix/matrix.dart';

final class FakeBusiness implements BusinessSessionGateway {
  FakeBusiness(this.result,
      {this.matrixUserId, this.error, this.logoutBlocker});
  final BusinessSessionRestore result;
  final String? matrixUserId;
  final Object? error;
  final Completer<void>? logoutBlocker;
  int logoutCalls = 0;
  @override
  Future<String?> currentMatrixUserId() async => matrixUserId;
  @override
  Future<void> logout() async {
    logoutCalls++;
    await logoutBlocker?.future;
  }

  @override
  Future<BusinessSessionRestore> restoreSession() async {
    if (error != null) throw error!;
    return result;
  }
}

final class FakeMatrix implements MatrixSessionGateway {
  FakeMatrix(
      {required this.isLoggedIn,
      this.userId,
      this.deviceId = 'DEVICE',
      this.syncError,
      this.suspendError,
      this.suspendBlocker});
  @override
  bool isLoggedIn;
  @override
  String? userId;
  @override
  String? deviceId;
  final Object? syncError;
  final Object? suspendError;
  final Completer<void>? suspendBlocker;
  int suspendCalls = 0;
  int clearCalls = 0;
  @override
  Future<void> suspend() async {
    suspendCalls++;
    if (suspendError != null) throw suspendError!;
    await suspendBlocker?.future;
  }

  @override
  Future<void> clearLocalChatData() async {
    clearCalls++;
    isLoggedIn = false;
  }

  @override
  Future<void> sync() async {
    if (syncError != null) throw syncError!;
  }
}

void main() {
  test('no persisted domains becomes unauthenticated', () async {
    final controller = SessionBootstrapController(
      business: FakeBusiness(BusinessSessionRestore.absent),
      matrix: FakeMatrix(isLoggedIn: false),
    );
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
    expect((controller.matrix as FakeMatrix).suspendCalls, 1);
  });

  test('bootstrap blocks chat access before Matrix suspension drains',
      () async {
    final blocker = Completer<void>();
    final controller = SessionBootstrapController(
      business: FakeBusiness(BusinessSessionRestore.absent),
      matrix: FakeMatrix(isLoggedIn: true, suspendBlocker: blocker),
    );

    final bootstrap = controller.bootstrap();
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
    blocker.complete();
    await bootstrap;
  });

  test('both restored domains become authenticated', () async {
    final controller = SessionBootstrapController(
      business: FakeBusiness(BusinessSessionRestore.authenticated,
          matrixUserId: '@alice:matrix.localhost'),
      matrix: FakeMatrix(isLoggedIn: true, userId: '@alice:matrix.localhost'),
    );
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.authenticated);
  });

  test('temporary network failure preserves an offline authenticated session',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.offline,
        matrixUserId: '@alice:matrix.localhost');
    final matrix = FakeMatrix(
        isLoggedIn: true,
        userId: '@alice:matrix.localhost',
        syncError: const SocketException('offline'));
    final controller =
        SessionBootstrapController(business: business, matrix: matrix);
    await controller.bootstrap();
    expect(
        controller.state.status, SessionBootstrapStatus.offlineAuthenticated);
    expect(business.logoutCalls, 0);
    expect(matrix.suspendCalls, 0);
    expect(matrix.clearCalls, 0);
  });

  for (final result in [
    BusinessSessionRestore.absent,
    BusinessSessionRestore.invalid,
  ]) {
    test('Business $result preserves a locally logged-in Matrix session',
        () async {
      final matrix =
          FakeMatrix(isLoggedIn: true, userId: '@alice:matrix.localhost');
      final controller = SessionBootstrapController(
        business: FakeBusiness(result),
        matrix: matrix,
      );

      await controller.bootstrap();

      expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
      expect(matrix.suspendCalls, 1);
      expect(matrix.clearCalls, 0);
    });
  }

  for (final errcode in ['M_UNKNOWN_TOKEN', 'M_FORBIDDEN']) {
    test('Matrix $errcode preserves chat data and returns to login', () async {
      final business = FakeBusiness(BusinessSessionRestore.authenticated,
          matrixUserId: '@alice:matrix.localhost');
      final matrix = FakeMatrix(
        isLoggedIn: true,
        userId: '@alice:matrix.localhost',
        syncError:
            MatrixException.fromJson({'errcode': errcode, 'error': 'expired'}),
      );
      final controller =
          SessionBootstrapController(business: business, matrix: matrix);

      await controller.bootstrap();

      expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
      expect(controller.state.message, '登录状态已失效，请重新登录');
      expect(business.logoutCalls, 1);
      expect(matrix.suspendCalls, 1);
      expect(matrix.clearCalls, 0);
    });
  }

  test('mismatched domain identities fail closed without deleting data',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost');
    final matrix =
        FakeMatrix(isLoggedIn: true, userId: '@mallory:matrix.localhost');
    final controller =
        SessionBootstrapController(business: business, matrix: matrix);
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.fatalError);
    expect(business.logoutCalls, 0);
    expect(matrix.suspendCalls, 0);
    expect(matrix.clearCalls, 0);
  });

  test('missing migrated Business MXID cannot authenticate a Matrix session',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated);
    final matrix = FakeMatrix(
      isLoggedIn: true,
      userId: '@mallory:matrix.localhost',
    );
    final controller =
        SessionBootstrapController(business: business, matrix: matrix);

    await controller.bootstrap();

    expect(controller.state.status, SessionBootstrapStatus.fatalError);
    expect(business.logoutCalls, 0);
    expect(matrix.suspendCalls, 0);
    expect(matrix.clearCalls, 0);
  });

  test('suspend failure clears Business and keeps Matrix data recoverable',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.absent);
    final matrix = FakeMatrix(
      isLoggedIn: true,
      userId: '@alice:matrix.localhost',
      suspendError: StateError('close failed'),
    );
    final controller =
        SessionBootstrapController(business: business, matrix: matrix);

    final previousDebugPrint = debugPrint;
    final diagnostics = <String>[];
    debugPrint = (message, {wrapWidth}) {
      if (message != null) diagnostics.add(message);
    };
    try {
      await controller.bootstrap();
    } finally {
      debugPrint = previousDebugPrint;
    }

    expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
    expect(controller.state.message, '聊天会话暂停失败，请重新打开应用后重试');
    expect(business.logoutCalls, 1);
    expect(matrix.suspendCalls, 1);
    expect(matrix.clearCalls, 0);
    expect(diagnostics, ['E2EE_LIFECYCLE_SUSPEND_FAILED']);
  });

  test('local storage failure becomes fatal error', () async {
    final controller = SessionBootstrapController(
      business: FakeBusiness(BusinessSessionRestore.absent,
          error: const FormatException('corrupt')),
      matrix: FakeMatrix(isLoggedIn: false),
    );
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.fatalError);
  });

  test('ordinary logout suspends Matrix without erasing its local store',
      () async {
    final business = FakeBusiness(BusinessSessionRestore.authenticated,
        matrixUserId: '@alice:matrix.localhost');
    final matrix =
        FakeMatrix(isLoggedIn: true, userId: '@alice:matrix.localhost');
    final controller = SessionBootstrapController(
      business: business,
      matrix: matrix,
    );
    await controller.logout();
    expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
    expect(business.logoutCalls, 1);
    expect(matrix.suspendCalls, 1);
    expect(matrix.clearCalls, 0);
  });

  test(
      'logout blocks chat access after Business clears and before suspend drains',
      () async {
    final blocker = Completer<void>();
    final business = FakeBusiness(BusinessSessionRestore.authenticated);
    final controller = SessionBootstrapController(
      business: business,
      matrix: FakeMatrix(isLoggedIn: true, suspendBlocker: blocker),
    );

    final logout = controller.logout();
    await Future<void>.delayed(Duration.zero);

    expect(business.logoutCalls, 1);
    expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
    blocker.complete();
    await logout;
  });
}
